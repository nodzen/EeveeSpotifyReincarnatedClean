import Orion
import SwiftUI
import MediaPlayer

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct LegacyScrollCaptureGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }            // 9.1.x-safe subset
struct V91LyricsAvailabilityGroup: HookGroup { } // SPTPlayerTrack metadata only
struct LyricsErrorHandlingGroup: HookGroup { }  // not activated on 9.1.x

var lyricsState = LyricsLoadingState()

var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()
private let lyricsMetadataLock = NSLock()
private var lyricsMetadataCache: [String: (title: String, artist: String)] = [:]
private var lyricsMetadataOrder: [String] = []

private func cachedLyricsMetadata(for trackId: String) -> (title: String, artist: String)? {
    lyricsMetadataLock.lock()
    defer { lyricsMetadataLock.unlock() }
    return lyricsMetadataCache[trackId]
}

private func storeLyricsMetadata(trackId: String, title: String, artist: String) {
    guard !trackId.isEmpty, !title.isEmpty, !artist.isEmpty else { return }

    lyricsMetadataLock.lock()
    lyricsMetadataCache[trackId] = (title, artist)
    lyricsMetadataOrder.removeAll { $0 == trackId }
    lyricsMetadataOrder.append(trackId)
    while lyricsMetadataOrder.count > 6 {
        let expiredTrackId = lyricsMetadataOrder.removeFirst()
        lyricsMetadataCache.removeValue(forKey: expiredTrackId)
    }
    lyricsMetadataLock.unlock()
}

private final class LyricsMetadataBox {
    private let lock = NSLock()
    private var value: (title: String, artist: String)?

    func store(title: String, artist: String) {
        lock.lock()
        value = (title, artist)
        lock.unlock()
    }

    func load() -> (title: String, artist: String)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LyricsBackgroundColorBox {
    private let lock = NSLock()
    private var value: UIColor?

    func store(_ color: UIColor?) {
        lock.lock()
        value = color
        lock.unlock()
    }

    func load() -> UIColor? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func readLyricsBackgroundColor() -> UIColor? {
    if Thread.isMainThread {
        return backgroundViewModel?.color()
    }

    let result = LyricsBackgroundColorBox()
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        result.store(backgroundViewModel?.color())
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 0.4) == .success else {
        writeDebugLog("[Lyrics] background-color snapshot timed out")
        return nil
    }
    return result.load()
}

/// Reads Spotify/MediaPlayer objects on the main queue without ever making the
/// main queue wait for a background lyrics request. A short timeout makes this
/// fail closed if the UI is busy during a track transition.
private func readLyricsMetadataOnMain(
    trackId: String,
    includeNowPlayingFallback: Bool
) -> (title: String, artist: String)? {
    let result = LyricsMetadataBox()
    let work = {
        if let track = statefulPlayer?.currentTrack(),
           track.URI().spt_trackIdentifier() == trackId {
            let title = track.trackTitle()
            let artist = track.artistName()
            if !title.isEmpty, !artist.isEmpty {
                result.store(title: title, artist: artist)
                return
            }
        }

        guard includeNowPlayingFallback else { return }
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        guard let title = info?[MPMediaItemPropertyTitle] as? String,
              let artist = info?[MPMediaItemPropertyArtist] as? String,
              !title.isEmpty,
              !artist.isEmpty else {
            return
        }
        result.store(title: title, artist: artist)
    }

    if Thread.isMainThread {
        work()
    } else {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            work()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 0.4) == .success else {
            writeDebugLog("[Lyrics] main-thread metadata snapshot timed out track=\(trackId)")
            return nil
        }
    }

    return result.load()
}

/// Resolves title/artist for the exact track ID from the lyrics URL. Player
/// objects are sampled on main with a bounded wait; the Web API is preferred
/// over unverified MediaPlayer metadata when the player has not caught up yet.
private func resolveLyricsMetadata(
    trackId: String,
    allowFallbackLookups: Bool
) -> (title: String, artist: String)? {
    if let metadata = cachedLyricsMetadata(for: trackId) {
        return metadata
    }

    if let playerMetadata = readLyricsMetadataOnMain(
        trackId: trackId,
        includeNowPlayingFallback: false
    ) {
        return playerMetadata
    }

    guard allowFallbackLookups else { return nil }

    // This lookup is keyed by the URL's track ID, so it remains correct even
    // when the local player object has not caught up with a fast catalog tap.
    if let token = SpotifyAccessTokenStore.value,
       let exactMetadata = fetchTrackDetails(trackId: trackId, token: token) {
        return exactMetadata
    }

    // No token (or unavailable Web API): media-center values are only the
    // final best-effort fallback because they may briefly describe the
    // previous track after a fast catalog tap.
    return readLyricsMetadataOnMain(
        trackId: trackId,
        includeNowPlayingFallback: true
    )
}

// Overload for 9.1.6 where we only have track ID from URL
private func loadCustomLyricsForTrackId(
    _ trackId: String,
    requestedSource: LyricsSource,
    options: LyricsOptions
) throws -> Lyrics {

    // Record the request before any network work starts. Karaoke responses
    // arrive independently and must not let an older track overwrite the
    // current track's stored syllable data.
    KaraokeLyricsStore.shared.noteRequestStarted(trackId: trackId)

    var source = requestedSource

    var currentTitle: String?
    var currentArtist: String?
    let needsMetadata = source == .genius || source == .lrclib || source == .petit

    if let info = resolveLyricsMetadata(
        trackId: trackId,
        allowFallbackLookups: true
    ) {
        currentTitle = info.title
        currentArtist = info.artist
        storeLyricsMetadata(trackId: trackId, title: info.title, artist: info.artist)
        writeDebugLog("[Lyrics] metadata resolved track=\(trackId)")
    }

    if needsMetadata && (currentTitle == nil || currentArtist == nil) {
        writeDebugLog("[Lyrics] metadata unavailable track=\(trackId)")
        throw LyricsError.noSuchSong
    }

    let searchQuery = LyricsSearchQuery(
        title: currentTitle ?? "",
        primaryArtist: currentArtist ?? "",
        spotifyTrackId: trackId
    )
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        let candidate = try repository.getLyrics(searchQuery, options: options)
        // LRCLIB represents instrumental tracks with a successful, but empty,
        // response. Treat that as a miss so the enabled Genius fallback can
        // still provide ordinary unsynchronised lyrics.
        guard !candidate.lines.isEmpty else {
            throw LyricsError.noSuchSong
        }
        lyricsDto = candidate
        writeDebugLog("[Lyrics] provider=\(source.description) loaded track=\(trackId) lines=\(candidate.lines.count) synced=\(candidate.timeSynced)")
    }
    catch let error {
        if let lyricsError = error as? LyricsError {
            lyricsState.fallbackError = lyricsError

            switch lyricsError {
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_unauthorized_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownUnauthorizedPopUp = true
                }
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_restricted_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownRestrictedPopUp = true
                }
            default:
                break
            }
        } else {
            lyricsState.fallbackError = .unknownError
        }

        // Attempt Genius fallback if enabled and the primary source isn't already Genius.
        // Genius requires title + artist to search — only attempt if we have them.
        let canFallbackToGenius = source != .genius
            && options.geniusFallback
            && !(currentTitle ?? "").isEmpty
            && !(currentArtist ?? "").isEmpty
        if canFallbackToGenius {
            writeDebugLog("[Lyrics] Primary source failed for \(trackId); trying Genius fallback")
            source = .genius
            do {
                let candidate = try geniusLyricsRepository.getLyrics(searchQuery, options: options)
                guard !candidate.lines.isEmpty else {
                    throw LyricsError.noSuchSong
                }
                lyricsDto = candidate
                writeDebugLog("[Lyrics] Genius fallback loaded \(lyricsDto.lines.count) lines for \(trackId)")
            } catch {
                writeDebugLog("[Lyrics] Genius fallback failed for \(trackId): \(error)")
                throw error
            }
        } else {
            throw error
        }
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && options.romanization)
    
    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackTitle = track.trackTitle()
    let artistName = track.artistName()

    KaraokeLyricsStore.shared.noteRequestStarted(trackId: track.trackIdentifier)

    let searchQuery = LyricsSearchQuery(
        title: trackTitle,
        primaryArtist: artistName,
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    var source = UserDefaults.lyricsSource
    
    // switched to swift 5.8 syntax to compile with Theos on Linux.
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        let candidate = try repository.getLyrics(searchQuery, options: options)
        guard !candidate.lines.isEmpty else {
            throw LyricsError.noSuchSong
        }
        lyricsDto = candidate
    }
    catch let error {
        if let error = error as? LyricsError {
            lyricsState.fallbackError = error
            
            switch error {
                
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_unauthorized_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownUnauthorizedPopUp.toggle()
                }
            
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_restricted_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownRestrictedPopUp.toggle()
                }
                
            default:
                break
            }
        }
        else {
            lyricsState.fallbackError = .unknownError
        }
        
        if source == .genius || !UserDefaults.lyricsOptions.geniusFallback {
            throw error
        }
        
        source = .genius
        repository = GeniusLyricsRepository()

        let candidate = try repository.getLyrics(searchQuery, options: options)
        guard !candidate.lines.isEmpty else {
            throw LyricsError.noSuchSong
        }
        lyricsDto = candidate
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

/// Extracts the Spotify track ID from a `/color-lyrics/v2/track/{trackId}` URL path.
/// Returns nil if the path doesn't match the expected format.
func extractTrackId(from path: String) -> String? {
    guard let range = path.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) else {
        return nil
    }
    let trackId = String(path[range].split(separator: "/").last ?? "")
    return trackId.isEmpty ? nil : trackId
}

// MARK: - Single-flight lyrics loading

/// One lower-card request and one under-cover request often arrive together.
/// They must share a single provider lookup; duplicate LRCLIB/Genius requests
/// used to outlive Spotify's response window and starve the callback queues.
private final class LyricsFetchEntry {
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var outcome: Result<Lyrics, Error>?

    init() {
        completion.enter()
    }

    func finish(_ newOutcome: Result<Lyrics, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = newOutcome
        lock.unlock()
        completion.leave()
    }

    func wait(timeout: DispatchTime) -> Result<Lyrics, Error>? {
        guard completion.wait(timeout: timeout) == .success else { return nil }
        lock.lock()
        let value = outcome
        lock.unlock()
        return value
    }

    var isFinished: Bool {
        lock.lock()
        let finished = outcome != nil
        lock.unlock()
        return finished
    }
}

private final class LyricsFetchCoordinator {
    private let lock = NSLock()
    private var entries: [String: LyricsFetchEntry] = [:]
    private var order: [String] = []

    func acquire(key: String) -> (entry: LyricsFetchEntry, shouldStart: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if let entry = entries[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return (entry, false)
        }

        // Keep completed handoff entries for both Spotify lyrics surfaces, but
        // discard older completed tracks. In-flight entries stay alive until
        // their URLSession task finishes.
        while entries.count >= 6,
              let expiredIndex = order.firstIndex(where: { entries[$0]?.isFinished == true }) {
            let expiredKey = order.remove(at: expiredIndex)
            entries.removeValue(forKey: expiredKey)
        }

        let entry = LyricsFetchEntry()
        entries[key] = entry
        order.append(key)
        return (entry, true)
    }

    func finish(
        key: String,
        entry: LyricsFetchEntry,
        outcome: Result<Lyrics, Error>
    ) {
        // Wake every waiter before touching the cache. Failed network/provider
        // results are deliberately not cached: a transient LRCLIB/Genius miss
        // must not make this track permanently lyric-less until six other
        // tracks have been played.
        entry.finish(outcome)

        guard case .failure = outcome else { return }

        lock.lock()
        if entries[key] === entry {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
        lock.unlock()
    }
}

private let lyricsFetchCoordinator = LyricsFetchCoordinator()

private func lyricsFetchKey(
    trackId: String,
    source: LyricsSource,
    options: LyricsOptions
) -> String {
    [
        trackId,
        String(source.rawValue),
        options.romanization ? "romanized" : "original",
        options.musixmatchLanguage,
        options.lrclibUrl,
        options.geniusFallback ? "fallback" : "no-fallback"
    ].joined(separator: "|")
}

/// Returns a serialized empty `Lyrics` protobuf payload.
/// Used as a fallback when every lyrics source (including Genius fallback) fails,
/// so we show "no lyrics" instead of leaking Spotify's own Musixmatch response.
func emptyLyricsData(originalLyrics: Lyrics? = nil) -> Data? {
    let emptyDto = LyricsDto(lines: [], timeSynced: false, romanization: .original, translation: nil)
    var lyrics = Lyrics.with {
        $0.data = emptyDto.toSpotifyLyricsData(source: "")
    }
    if let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    return try? lyrics.serializedData()
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    // All URLSession hooks schedule this function away from their delegate and
    // UI queues. Fail closed if a future call site violates that contract.
    guard !Thread.isMainThread else {
        writeDebugLog("[Lyrics] refused blocking provider lookup on main thread")
        throw LyricsError.noSuchSong
    }

    // track id from URL path; player objects are nil on 9.1.6
    // path: /color-lyrics/v2/track/{trackId}
    guard let trackIdentifier = extractTrackId(from: originalPath), !trackIdentifier.isEmpty else {
        throw LyricsError.noCurrentTrack
    }

    // The lyrics URL is reliable even on Spotify 9.1 builds where the player
    // observer hook is unavailable, so use it to keep the karaoke launcher
    // associated with the actual current track.
    KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(trackIdentifier)

    let currentSource = UserDefaults.lyricsSource
    let currentOptions = UserDefaults.lyricsOptions
    writeDebugLog("[Lyrics] request track=\(trackIdentifier) source=\(currentSource.description) nativeLines=\(originalLyrics?.data.lines.count ?? -1)")
    let fetchKey = lyricsFetchKey(
        trackId: trackIdentifier,
        source: currentSource,
        options: currentOptions
    )
    let acquired = lyricsFetchCoordinator.acquire(key: fetchKey)

    if acquired.shouldStart {
        writeDebugLog("[Lyrics] single-flight start track=\(trackIdentifier)")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let lyrics = try loadCustomLyricsForTrackId(
                    trackIdentifier,
                    requestedSource: currentSource,
                    options: currentOptions
                )
                lyricsFetchCoordinator.finish(
                    key: fetchKey,
                    entry: acquired.entry,
                    outcome: .success(lyrics)
                )
            } catch {
                lyricsFetchCoordinator.finish(
                    key: fetchKey,
                    entry: acquired.entry,
                    outcome: .failure(error)
                )
            }
        }
    } else {
        writeDebugLog("[Lyrics] joined existing fetch track=\(trackIdentifier)")
    }

    guard let outcome = acquired.entry.wait(timeout: .now() + 18.0) else {
        writeDebugLog("[Lyrics] fetch for \(trackIdentifier) exceeded 18s; returning no lyrics")
        throw LyricsError.noSuchSong
    }

    var lyrics: Lyrics
    switch outcome {
    case .success(let fetchedLyrics):
        lyrics = fetchedLyrics
    case .failure(let error):
        writeDebugLog("[Lyrics] fetch failed track=\(trackIdentifier): \(error)")
        throw error
    }
    
    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        // no track object on 9.1.6: static color, else background color, else gray
        var color: Color
        
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let uiColor = readLyricsBackgroundColor() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
            color = Color.gray
        }
        
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
    }
    
    let serialized = try lyrics.serializedData()
    writeDebugLog("[Lyrics] payload ready track=\(trackIdentifier) lines=\(lyrics.data.lines.count) synced=\(lyrics.data.timeSynchronized)")
    return serialized
}
