import Foundation

class GeniusLyricsRepository: LyricsRepository {
    private let jsonDecoder: JSONDecoder
    private let apiUrl = "https://api.genius.com"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // This repository is used as a fallback from the synchronous lyrics
        // loader. Keep each search/song request bounded so a dead Genius
        // connection cannot outlive the loader's overall deadline forever.
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpAdditionalHeaders = [
            "X-Genius-iOS-Version": "6.21.0",
            "X-Genius-Logged-Out": "true",
            "User-Agent": "Genius/1109 \(URLSessionHelper.CFNetworkVersion) \(URLSessionHelper.DarwinVersion)"
        ]
        
        session = URLSession(configuration: configuration)
        
        jsonDecoder = JSONDecoder()
        jsonDecoder.keyDecodingStrategy = .convertFromSnakeCase
    }
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> GeniusDataResponse? {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        let request = URLRequest(url: URL(string: stringUrl)!)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?

        let task = session.dataTask(with: request) { response, _, err in
            error = err
            data = response
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let error = error {
            throw error
        }

        guard let data,
              let rootResponse = try? jsonDecoder.decode(GeniusRootResponse.self, from: data) else {
            throw LyricsError.decodingError
        }
        return rootResponse.response
    }
    
    
    private func searchSong(_ query: String) throws -> [GeniusHit] {
        let data = try perform("/search/song", query: ["q": query])
        
        guard
            case .sections(let sectionsResponse) = data,
            let section = sectionsResponse.sections.first
        else {
            throw LyricsError.decodingError
        }
        
        return section.hits
    }

    private func getSongInfo(_ songId: Int) throws -> GeniusSong {
        let data = try perform("/songs/\(songId)", query: ["text_format": "plain"])
        
        guard case .song(let songResponse) = data else {
            throw LyricsError.decodingError
        }
        
        return songResponse.song
    }
    
    
    private func mostRelevantHitResult(
        hits: [GeniusHit],
        strippedTitle: String,
        primaryArtist: String,
        romanized: Bool,
        hasFoundRomanizedLyrics: inout Bool
    ) -> GeniusHitResult {
        let results = hits.map { $0.result }

        // Genius search also returns localized/translated pages. They often
        // have the same title but are attributed to e.g. "Genius Russian
        // Translations", so title-only selection can show a translation for
        // an ordinary track. Keep those pages out of the normal pool; the
        // romanization switch has its own explicit selection below.
        let normalResults = results.filter { result in
            let artist = result.artistNames.lowercased()
            let title = result.title.lowercased()
            let isTranslationArtist = artist.contains("genius") && (
                artist.contains("translation")
                    || artist.contains("перевод")
                    || artist.contains("tradu")
                    || artist.contains("traduzione")
                    || artist.contains("tłumac")
            )
            let isRomanizationArtist = artist.contains("genius")
                && artist.contains("romanization")
            let isTranslationTitle = title.contains("translation")
                || title.contains("перевод")
                || title.contains("traducción")
                || title.contains("traducao")
                || title.contains("traduzione")
                || title.contains("tłumaczenie")
            return !isTranslationArtist
                && !isTranslationTitle
                && (romanized || !isRomanizationArtist)
        }

        // Spotify sends a comma-separated artist list for collaborations,
        // while Genius commonly indexes only the primary artist. Matching the
        // complete string misses the original page and lets a translation win
        // as the first title-only result (Cracks is one such case).
        let artistParts = primaryArtist
            .replacingOccurrences(of: " featuring ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " feat. ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " feat ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " ft. ", with: ",", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: ",&/"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func matchesAnArtist(_ result: GeniusHitResult) -> Bool {
            artistParts.contains { result.artistNames.containsInsensitive($0) }
        }

        let matchingByTitle = normalResults.filter {
            $0.title.containsInsensitive(strippedTitle)
        }

        let strippedArtist = primaryArtist.strippedTrackTitle
        let matchingByBoth = matchingByTitle.filter {
            matchesAnArtist($0)
                || $0.artistNames.containsInsensitive(strippedArtist)
                || $0.artistNames.containsInsensitive(primaryArtist)
        }

        // Best match: title+artist → title only → first result
        let pool = !matchingByBoth.isEmpty ? matchingByBoth
                 : !matchingByTitle.isEmpty ? matchingByTitle
                 : normalResults.isEmpty ? results : normalResults

        if romanized, let romanizedSong = pool.first(
            where: { $0.artistNames == "Genius Romanizations" }
        ) {
            hasFoundRomanizedLyrics = true
            return romanizedSong
        }

        let selected = pool.first!
        writeDebugLog("[Genius] selected id=\(selected.id) title=\(selected.title) artist=\(selected.artistNames) romanized=\(romanized)")
        return selected
    }
    
    private func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        lines.removeAll { $0 ~= "\\[.*\\]" }

        lines = Array(
            lines
                .drop(while: { $0.isEmpty })
                .dropLast(while: { $0.isEmpty })
        )
        
        return lines
    }
    
    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let strippedTitle = query.title.strippedTrackTitle
        let hits = try searchSong("\(strippedTitle) \(query.primaryArtist)")
    
        guard !hits.isEmpty else {
            throw LyricsError.noSuchSong
        }
        
        var hasFoundRomanizedLyrics = false
        
        let song = mostRelevantHitResult(
            hits: hits,
            strippedTitle: strippedTitle,
            primaryArtist: query.primaryArtist,
            romanized: options.romanization,
            hasFoundRomanizedLyrics: &hasFoundRomanizedLyrics
        )
        
        let songInfo = try getSongInfo(song.id)
        let plainLines = songInfo.lyrics.plain.components(separatedBy: "\n")
        
        var romanization = LyricsRomanizationStatus.original
        
        if hasFoundRomanizedLyrics {
            romanization = .romanized
        }
        else if songInfo.language.isCanBeRomanizedLanguage {
            romanization = .canBeRomanized
        }
    
        return LyricsDto(
            lines: mapLyricsLines(plainLines).map { line in LyricsLineDto(content: line) },
            timeSynced: false,
            romanization: romanization
        )
    }
}
