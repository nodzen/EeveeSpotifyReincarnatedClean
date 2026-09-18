import Foundation

class LrclibLyricsRepository: LyricsRepository {
    var apiUrl: String
    private let session: URLSession

    private init(apiUrl: String) {
        self.apiUrl = apiUrl
        
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            "User-Agent": "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify"
        ]
        // LRCLIB is unreachable on some networks (including the user's
        // Russian route) and otherwise holds the Spotify lyrics response for
        // the full timeout before Genius fallback can run. Keep this short so
        // the fallback provider can still populate the card in time.
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }
    
    static let originalApiUrl = "https://lrclib.net/api"
    
    static let shared = LrclibLyricsRepository(
        apiUrl: UserDefaults.lyricsOptions.lrclibUrl
    )
    
    private func perform(
        _ path: String, 
        query: [String:Any] = [:]
    ) throws -> Data {
        var stringUrl = "\(apiUrl)\(path)"

        if !query.isEmpty {
            let queryString = query.queryString
            stringUrl += "?\(queryString)"
        }
        
        guard let url = URL(string: stringUrl) else {
            throw LyricsError.decodingError
        }

        var request = URLRequest(url: url)

        request.setValue(
            "EeveeSpotify v\(EeveeSpotify.version) https://github.com/whoeevee/EeveeSpotify",
            forHTTPHeaderField: "User-Agent"
        )

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var error: Error?
        var statusCode: Int?

        let task = session.dataTask(with: request) { responseData, response, err in
            error = err
            data = responseData
            statusCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        if let error = error {
            writeDebugLog("[LRCLIB] Request error for \(stringUrl): \(error)")
            throw error
        }

        guard let statusCode, (200..<300).contains(statusCode) else {
            writeDebugLog("[LRCLIB] HTTP \(statusCode ?? -1) for \(stringUrl)")
            throw LyricsError.noSuchSong
        }

        guard let data else {
            writeDebugLog("[LRCLIB] No data returned for \(stringUrl)")
            throw LyricsError.decodingError
        }
        writeDebugLog("[LRCLIB] \(stringUrl) -> \(data.count) bytes")
        return data
    }
    
    private func getSong(trackName: String, artistName: String) throws -> LrclibSong {
        let data: Data = try perform("/get", query: [
            "track_name": trackName,
            "artist_name": artistName
        ])
        do {
            return try JSONDecoder().decode(LrclibSong.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            writeDebugLog("[LRCLIB] Decode error for \(trackName)/\(artistName): \(error). Body: \(body.prefix(300))")
            throw error
        }
    }
    
    private func mapSyncedLyricsLines(_ lines: [String]) -> [LyricsLineDto] {
        return lines.compactMap { line in
            guard let match = line.firstMatch(
                "\\[(?<minute>\\d+):(?<seconds>\\d+\\.\\d+|\\d+)\\] ?(?<content>.*)"
            ) else {
                return nil
            }
            
            var captures: [String: String] = [:]
            
            for name in ["minute", "seconds", "content"] {
                let matchRange = match.range(withName: name)
                
                if let substringRange = Range(matchRange, in: line) {
                    captures[name] = String(line[substringRange])
                }
            }
            
            guard let minuteText = captures["minute"],
                  let minute = Int(minuteText),
                  let secondsText = captures["seconds"],
                  let seconds = Float(secondsText),
                  let content = captures["content"] else {
                writeDebugLog("[LRCLIB] Ignoring malformed synchronized line: \(line.prefix(120))")
                return nil
            }
            
            return LyricsLineDto(
                content: content.lyricsNoteIfEmpty,
                offsetMs: Int(minute * 60 * 1000 + Int(seconds * 1000))
            )
        }
    }

    private func splitLyricsLines(_ lyrics: String) -> [String] {
        var lines = lyrics.components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }

        // components(separatedBy:) adds an empty element only when the response
        // actually ends in a newline. LRCLIB responses commonly do not, so an
        // unconditional dropLast() removes a real lyric line.
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        let song: LrclibSong

        do {
            song = try getSong(trackName: query.title, artistName: query.primaryArtist)
        } catch {
            // A network failure will not be fixed by sending the same request
            // with a stripped title. Let the configured Genius fallback start
            // immediately instead of spending another full timeout on LRCLIB.
            if (error as NSError).domain == NSURLErrorDomain {
                throw error
            }

            let strippedTitle = query.title.strippedTrackTitle
            guard strippedTitle != query.title else {
                throw error
            }
            do {
                song = try getSong(trackName: strippedTitle, artistName: query.primaryArtist)
            } catch {
                throw LyricsError.noSuchSong
            }
        }

        if song.instrumental {
            return LyricsDto(
                lines: [],
                timeSynced: false,
                romanization: .original
            )
        }

        if let syncedLyrics = song.syncedLyrics, !syncedLyrics.isEmpty {
            let lines = splitLyricsLines(syncedLyrics)
            let mappedLines = mapSyncedLyricsLines(lines)
            if !mappedLines.isEmpty {
                writeDebugLog("[LRCLIB] Loaded \(mappedLines.count) synced lines for \(query.spotifyTrackId)")
                return LyricsDto(
                    lines: mappedLines,
                    timeSynced: true,
                    romanization: lines.canBeRomanized ? .canBeRomanized : .original
                )
            }
        }
        
        guard let plainLyrics = song.plainLyrics, !plainLyrics.isEmpty else {
            writeDebugLog("[LRCLIB] No usable lyrics for \(query.spotifyTrackId); allowing configured fallback")
            throw LyricsError.noSuchSong
        }
        
        let lines = splitLyricsLines(plainLyrics)
        guard !lines.isEmpty else {
            writeDebugLog("[LRCLIB] Empty plain lyrics for \(query.spotifyTrackId); allowing configured fallback")
            throw LyricsError.noSuchSong
        }

        writeDebugLog("[LRCLIB] Loaded \(lines.count) plain lines for \(query.spotifyTrackId)")
        
        return LyricsDto(
            lines: lines.map { content in LyricsLineDto(content: content) },
            timeSynced: false,
            romanization: lines.canBeRomanized ? .canBeRomanized : .original
        )
    }
}
