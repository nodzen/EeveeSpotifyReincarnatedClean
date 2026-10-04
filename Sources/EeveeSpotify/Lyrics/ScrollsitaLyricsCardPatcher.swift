import Foundation

/// Spotify 9.1.x no longer derives the lower lyrics card from the
/// `/color-lyrics` response. The card first has to be present in the
/// Scrollsita `NpvScrollResponse`; tracks without catalog lyrics arrive without
/// that section, even when an external provider can supply a valid payload.
///
/// This patcher performs one narrow protobuf edit:
///
/// NpvScrollResponse.structure (#1)
///   -> NpvScrollStructure.sections (#1, repeated)
///      -> Section.lyrics (#5)
///      -> Section.section_info (#23 on Spotify 9.1.80)
///
/// The field numbers were verified against Spotify 9.1.80's generated
/// `Spotify_Scrollsita_V1_*` message implementations. Existing fields remain
/// byte-for-byte unchanged.
enum ScrollsitaLyricsCardPatcher {
    private static let lyricsFieldNumber = 5
    private static let sectionInfoFieldNumber = 23

    private struct WireField {
        let number: Int
        let wireType: UInt8
        let fieldStart: Int
        let lengthStart: Int?
        let payloadStart: Int?
        let payloadEnd: Int?
        let fieldEnd: Int
    }

    private static let contextLock = NSLock()
    private static var latestLyricsRequest: (id: String, timestamp: Date)?
    private static var latestScrollsitaRequest: (id: String, timestamp: Date)?
    private static var latestPlaybackTrack: (id: String, timestamp: Date)?
    private static var latestScrollsitaPublication: (id: String, timestamp: Date)?
    private static var latestExternalLyricsReady: (id: String, timestamp: Date)?
    private static var lastLyricsUIRefresh: (id: String, timestamp: Date)?
    /// Returns true only after the UIKit side has actually found and reloaded
    /// the visible NPV collection view. A false result is retried because a
    /// provider can finish while the Now Playing controller is between its
    /// disappear/appear callbacks.
    private static var lyricsUIRefreshHandler: ((String) -> Bool)?

    /// Playback events exist even when Spotify does not request lyrics or
    /// Scrollsita. Network activity must not overwrite this observed identity.
    @discardableResult
    static func notePlaybackTrack(_ trackID: String) -> Bool {
        guard !trackID.isEmpty else { return false }
        contextLock.lock()
        defer { contextLock.unlock() }
        let changed = latestPlaybackTrack?.id != trackID
        latestPlaybackTrack = (trackID, Date())
        return changed
    }

    /// Returns true only when the playback observer has identified this exact
    /// track recently. Unlike the generic currentTrackID() fallback, this is
    /// safe to use when reading artwork: a late MediaPlayer snapshot must not
    /// make a previous song's cover determine the new lyrics palette.
    static func isCurrentPlaybackTrack(_ trackID: String) -> Bool {
        guard !trackID.isEmpty else { return false }
        contextLock.lock()
        defer { contextLock.unlock() }
        guard let playback = latestPlaybackTrack else { return false }
        return playback.id == trackID
            && Date().timeIntervalSince(playback.timestamp) <= currentTrackLifetime
    }

    /// Installed by the iOS NPV hook. Keeping the UIKit-specific part outside
    /// this parser lets the standalone protobuf regression tests compile on
    /// macOS as well.
    static func installLyricsUIRefreshHandler(_ handler: @escaping (String) -> Bool) {
        contextLock.lock()
        lyricsUIRefreshHandler = handler
        let now = Date()
        let pendingTrack: String? = {
            guard let published = latestScrollsitaPublication,
                  let ready = latestExternalLyricsReady,
                  published.id == ready.id,
                  now.timeIntervalSince(published.timestamp) <= currentTrackLifetime,
                  now.timeIntervalSince(ready.timestamp) <= currentTrackLifetime else {
                return nil
            }
            return published.id
        }()
        contextLock.unlock()

        // The first NPV instance can be installed after the network callbacks
        // have already completed. Do not lose that pending refresh merely
        // because the handler was not present at the time of the race.
        if let pendingTrack {
            scheduleLyricsUIRefresh(for: pendingTrack)
        }
    }

    /// Called from viewWillAppear after Spotify has attached the NPV view to a
    /// window. This covers the case where the provider completed while the
    /// screen was hidden and the first refresh attempt was deferred.
    static func retryLyricsUIRefreshIfNeeded() {
        contextLock.lock()
        let now = Date()
        let pendingTrack: String? = {
            guard let published = latestScrollsitaPublication,
                  let ready = latestExternalLyricsReady,
                  published.id == ready.id,
                  now.timeIntervalSince(published.timestamp) <= currentTrackLifetime,
                  now.timeIntervalSince(ready.timestamp) <= currentTrackLifetime else {
                return nil
            }
            return published.id
        }()
        contextLock.unlock()

        if let pendingTrack {
            scheduleLyricsUIRefresh(for: pendingTrack)
        }
    }

    /// The Scrollsita structure is often rendered before the external
    /// provider returns. Spotify 9.1.80 does not observe our later
    /// /color-lyrics payload, so remember both sides of that race and refresh
    /// the already-visible controller once the pair is complete.
    static func noteScrollsitaPublished(_ trackID: String) {
        guard !trackID.isEmpty else { return }

        contextLock.lock()
        let now = Date()
        latestScrollsitaPublication = (trackID, now)
        let shouldRefresh = latestExternalLyricsReady?.id == trackID
            && now.timeIntervalSince(latestExternalLyricsReady!.timestamp) <= currentTrackLifetime
        contextLock.unlock()

        if shouldRefresh {
            scheduleLyricsUIRefresh(for: trackID)
        }
    }

    /// Called after a non-empty external payload has been assembled. The
    /// refresh is deliberately deferred to the main queue and deduplicated;
    /// the same single-flight result can be consumed by several Spotify tasks.
    static func noteExternalLyricsReady(_ trackID: String) {
        guard !trackID.isEmpty else { return }

        contextLock.lock()
        let now = Date()
        latestExternalLyricsReady = (trackID, now)
        let shouldRefresh = latestScrollsitaPublication?.id == trackID
            && now.timeIntervalSince(latestScrollsitaPublication!.timestamp) <= currentTrackLifetime
        contextLock.unlock()

        if shouldRefresh {
            scheduleLyricsUIRefresh(for: trackID)
        }
    }

    private static func scheduleLyricsUIRefresh(for trackID: String, attempt: Int = 0) {
        contextLock.lock()
        let handler = lyricsUIRefreshHandler
        contextLock.unlock()

        guard handler != nil else {
            writeDebugLog("[LyricsUI] refresh handler is not installed track=\(trackID)")
            return
        }

        let delay = attempt == 0 ? 0.1 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard currentTrackID() == trackID else {
                writeDebugLog("[LyricsUI] skipped refresh for stale track=\(trackID)")
                return
            }

            contextLock.lock()
            let now = Date()
            let alreadyRefreshed = lastLyricsUIRefresh?.id == trackID
                && now.timeIntervalSince(lastLyricsUIRefresh!.timestamp) < 1.0
            contextLock.unlock()

            guard !alreadyRefreshed else { return }

            guard let handler else { return }
            if handler(trackID) {
                contextLock.lock()
                lastLyricsUIRefresh = (trackID, Date())
                contextLock.unlock()
            }
            else if attempt < 8 {
                writeDebugLog("[LyricsUI] refresh retry=\(attempt + 1) track=\(trackID)")
                scheduleLyricsUIRefresh(for: trackID, attempt: attempt + 1)
            }
            else {
                writeDebugLog("[LyricsUI] refresh failed after retries track=\(trackID)")
            }
        }
    }
    private static var nativeLyricsSectionTemplate: Data?
    private static var nativeLyricsSectionIndex: Int?
    private static let nativeTemplateDefaultsKey = "eevee.scrollsita.nativeLyricsSection.9180"
    private static let nativeIndexDefaultsKey = "eevee.scrollsita.nativeLyricsSectionIndex.9180"
    private static let currentTrackLifetime: TimeInterval = 45
    private static let spotifyTrackPrefix = Array("spotify:track:".utf8)

    static func shouldHandle(_ url: URL) -> Bool {
        url.path.lowercased().contains("/scrollsita/v1/scroll")
    }

    /// Resolves the response's own entity before consulting recent global
    /// context. Scrollsita payloads can contain recommendation URIs for other
    /// tracks, so the request URL remains the authoritative source.
    static func responseTrackID(_ data: Data, url: URL) -> String? {
        guard shouldHandle(url) else { return nil }

        let decodedURL = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        return embeddedTrackID(in: Array(decodedURL.utf8))
            ?? recentCurrentTrackID()
            ?? embeddedTrackID(in: [UInt8](data))
    }

    /// Called as soon as a color-lyrics task is resumed/observed. This gives
    /// the parallel Scrollsita request the exact current track even when its
    /// URL does not expose the entity URI.
    static func noteLyricsRequest(_ url: URL) {
        guard url.isLyrics, let trackID = trackIDFromLyricsPath(url.path) else {
            return
        }

        contextLock.lock()
        latestLyricsRequest = (trackID, Date())
        contextLock.unlock()
        writeDebugLog("[LyricsNetwork] Spotify requested lyrics track=\(trackID)")
    }

    /// Spotify 9.1.80's `ScrollsitaRequest` carries `entityUri`. Capture it
    /// from the outgoing URL or protobuf body so the lower card also works
    /// when the user has disabled the independent under-cover lyrics surface
    /// and no color-lyrics request has started yet.
    @discardableResult
    static func noteScrollsitaRequest(_ request: URLRequest) -> String? {
        guard let url = request.url, shouldHandle(url) else { return nil }

        let decodedURL = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let trackID = embeddedTrackID(in: Array(decodedURL.utf8))
            ?? request.httpBody.flatMap { embeddedTrackID(in: [UInt8]($0)) }
        guard let trackID else { return nil }

        contextLock.lock()
        latestScrollsitaRequest = (trackID, Date())
        contextLock.unlock()
        writeDebugLog("[LyricsNetwork] Spotify requested Scrollsita track=\(trackID)")
        return trackID
    }

    /// A provider lookup may finish after the user has already selected a
    /// different track. Spotify 9.1.x reuses its lyrics element during that
    /// transition, so delivering the old task can paint the previous lyrics
    /// into the new card. Compare the task URI with the newest request that was
    /// actually started and fail open only when no recent track context exists.
    static func shouldDeliverLyricsResponse(_ url: URL) -> Bool {
        guard url.isLyrics, let responseTrackID = trackIDFromLyricsPath(url.path) else {
            return true
        }

        guard let currentTrackID = recentCurrentTrackID() else { return true }
        return responseTrackID == currentTrackID
    }

    /// Best available visible-track context, used for prefetch and legacy UI
    /// state only. Response payloads must always retain their own request ID.
    static func currentTrackID() -> String? {
        recentCurrentTrackID()
    }

    /// Returns a modified response when the server omitted the lyrics section
    /// or when Spotify reused the previous track's lyrics section identity.
    ///
    /// Spotify 9.1.80 keeps the lower-card section in the response after a
    /// track change, but its `section_info` URI is often the same for every
    /// track. Returning nil for that response leaves the diffable data source
    /// with the old item, so the external payload is not rendered until the
    /// whole NPV UI is recreated. Rewrite the existing section in place and
    /// preserve its position and all unrelated fields.
    static func injectLyricsSectionIfMissing(_ data: Data, url: URL) -> Data? {
        guard shouldHandle(url) else { return nil }

        let bytes = [UInt8](data)
        guard let responseFields = parseFields(bytes, in: 0..<bytes.count),
              let structureField = responseFields.first(where: {
                  $0.number == 1 && $0.wireType == 2
              }),
              let structureStart = structureField.payloadStart,
              let structureEnd = structureField.payloadEnd,
              let structureFields = parseFields(bytes, in: structureStart..<structureEnd)
        else {
            writeDebugLog("[ScrollsitaLyrics] response shape did not match NpvScrollResponse")
            return nil
        }

        let sectionFields = structureFields.filter {
            $0.number == 1 && $0.wireType == 2
        }

        // Prefer the request URL, then the most recent request context. The
        // response body may contain recommendation/queue URIs, so it is only
        // used as the final fallback by responseTrackID().
        let trackID = responseTrackID(data, url: url)
        let currentTrackURI = trackID.map { "spotify:track:\($0)" }
        let currentSectionURI = trackID.map { "spotify:section:\($0)" }

        for (sectionIndex, sectionField) in sectionFields.enumerated() {
            guard let sectionStart = sectionField.payloadStart,
                  let sectionEnd = sectionField.payloadEnd,
                  let sectionFields = parseFields(bytes, in: sectionStart..<sectionEnd)
            else { continue }

            if sectionFields.contains(where: {
                $0.number == lyricsFieldNumber && $0.wireType == 2
            }) {
                let nativeSection = Data(bytes[sectionStart..<sectionEnd])
                cacheNativeLyricsSection(nativeSection, index: sectionIndex)
                let shape = sectionFields.map { "\($0.number):\($0.wireType)" }.joined(separator: ",")

                guard let trackURI = currentTrackURI,
                      let sectionURI = currentSectionURI else {
                    writeDebugLog("[ScrollsitaLyrics] native section kept: current track ID unavailable index=\(sectionIndex) path=\(url.path)")
                    return nil
                }

                guard let rewrittenSection = lyricsSection(
                    from: [UInt8](nativeSection),
                    trackURI: trackURI,
                    sectionURI: sectionURI
                ) else {
                    writeDebugLog("[ScrollsitaLyrics] native section kept: rewrite failed index=\(sectionIndex) fields=[\(shape)] path=\(url.path)")
                    return nil
                }

                let originalSection = [UInt8](nativeSection)
                guard rewrittenSection != originalSection else {
                    let logTrackID = trackID ?? "?"
                    writeDebugLog("[ScrollsitaLyrics] native section already current index=\(sectionIndex) track=\(logTrackID) fields=[\(shape)] path=\(url.path)")
                    return nil
                }

                var replacement = [UInt8]()
                appendMessageField(number: 1, payload: rewrittenSection, to: &replacement)

                let relativeStart = sectionField.fieldStart - structureStart
                let relativeEnd = sectionField.fieldEnd - structureStart
                var newStructure = Array(bytes[structureStart..<structureEnd])
                newStructure.replaceSubrange(relativeStart..<relativeEnd, with: replacement)

                guard let result = replacingStructure(
                    in: bytes,
                    structureField: structureField,
                    structure: newStructure
                ) else {
                    let logTrackID = trackID ?? "?"
                    writeDebugLog("[ScrollsitaLyrics] native section rewrite could not rebuild response index=\(sectionIndex) track=\(logTrackID) path=\(url.path)")
                    return nil
                }

                let logTrackID = trackID ?? "?"
                writeDebugLog("[ScrollsitaLyrics] rewrote lower lyrics card existingSection=true uniqueSection=true track=\(logTrackID) index=\(sectionIndex) \(data.count)->\(result.count) path=\(url.path)")
                return result
            }
        }

        // Prefer request identity over arbitrary entity URIs embedded in card
        // payloads (recommendations and queue sections contain other tracks).
        guard let trackID = trackID else {
            writeDebugLog("[ScrollsitaLyrics] skipped injection: current track ID unavailable path=\(url.path)")
            return nil
        }

        let trackURI = "spotify:track:\(trackID)"
        let sectionURI = "spotify:section:\(trackID)"

        let template = loadNativeLyricsSection()
        let section: [UInt8]
        if let template,
           let rewritten = lyricsSection(
               from: [UInt8](template),
               trackURI: trackURI,
               sectionURI: sectionURI
           ) {
            section = rewritten
        } else {
            // Match 9.1.80's native shape. A per-track section URI is required:
            // reusing the cached template's identifier makes the diffable data
            // source treat a new injected card as the previous track's item.
            var sectionInfo = [UInt8]()
            appendStringField(number: 1, value: sectionURI, to: &sectionInfo)

            var lyrics = [UInt8]()
            appendStringField(number: 1, value: trackURI, to: &lyrics)

            var fallbackSection = [UInt8]()
            appendMessageField(number: lyricsFieldNumber, payload: lyrics, to: &fallbackSection)
            appendMessageField(number: sectionInfoFieldNumber, payload: sectionInfo, to: &fallbackSection)
            section = fallbackSection
        }

        // The native lyrics card is near the beginning of the NPV section
        // list. Appending it after queue/recommendation terminal sections makes
        // Spotify's element factory silently ignore it. Reuse the last observed
        // native index, or position it first on a cold start.
        let preferredIndex = min(loadNativeLyricsSectionIndex() ?? 0, sectionFields.count)
        let insertionOffset: Int
        if preferredIndex < sectionFields.count {
            insertionOffset = sectionFields[preferredIndex].fieldStart - structureStart
        } else if let lastSection = sectionFields.last {
            insertionOffset = lastSection.fieldEnd - structureStart
        } else {
            insertionOffset = newStructureInsertionOffset(
                structureFields: structureFields,
                structureStart: structureStart,
                structureEnd: structureEnd
            )
        }

        var newStructure = Array(bytes[structureStart..<structureEnd])
        var encodedSection = [UInt8]()
        appendMessageField(number: 1, payload: section, to: &encodedSection)
        newStructure.insert(contentsOf: encodedSection, at: insertionOffset)

        guard let lengthStart = structureField.lengthStart else { return nil }
        var result = Array(bytes[..<lengthStart])
        result.append(contentsOf: encodeVarint(UInt64(newStructure.count)))
        result.append(contentsOf: newStructure)
        result.append(contentsOf: bytes[structureField.fieldEnd...])

        writeDebugLog("[ScrollsitaLyrics] injected lower lyrics card schema=lyrics#5/info#23 uniqueSection=true track=\(trackID) index=\(preferredIndex) template=\(template != nil) \(data.count)->\(result.count)")
        return Data(result)
    }

    private static func replacingStructure(
        in bytes: [UInt8],
        structureField: WireField,
        structure: [UInt8]
    ) -> Data? {
        guard let lengthStart = structureField.lengthStart else { return nil }

        var result = Array(bytes[..<lengthStart])
        result.append(contentsOf: encodeVarint(UInt64(structure.count)))
        result.append(contentsOf: structure)
        result.append(contentsOf: bytes[structureField.fieldEnd...])
        return Data(result)
    }

    private static func recentCurrentTrackID() -> String? {
        contextLock.lock()
        defer { contextLock.unlock() }

        let now = Date()

        if let playback = latestPlaybackTrack,
           now.timeIntervalSince(playback.timestamp) <= currentTrackLifetime {
            return playback.id
        }

        // Scrollsita describes the visible NPV entity. It is deliberately
        // preferred over a later-resumed color-lyrics task: during a fast
        // transition Spotify can resume the previous track's lyrics request
        // after it has already started the new Scrollsita request. Choosing
        // whichever callback happened last would resurrect the old track.
        if let scroll = latestScrollsitaRequest,
           now.timeIntervalSince(scroll.timestamp) <= currentTrackLifetime {
            return scroll.id
        }

        guard let lyrics = latestLyricsRequest,
              now.timeIntervalSince(lyrics.timestamp) <= currentTrackLifetime else {
            return nil
        }
        return lyrics.id
    }

    private static func cacheNativeLyricsSection(_ section: Data, index: Int) {
        contextLock.lock()
        nativeLyricsSectionTemplate = section
        nativeLyricsSectionIndex = index
        contextLock.unlock()

        UserDefaults.standard.set(section, forKey: nativeTemplateDefaultsKey)
        UserDefaults.standard.set(index, forKey: nativeIndexDefaultsKey)
    }

    private static func loadNativeLyricsSection() -> Data? {
        contextLock.lock()
        if let section = nativeLyricsSectionTemplate {
            contextLock.unlock()
            return section
        }
        contextLock.unlock()

        guard let section = UserDefaults.standard.data(forKey: nativeTemplateDefaultsKey) else {
            return nil
        }

        contextLock.lock()
        nativeLyricsSectionTemplate = section
        contextLock.unlock()
        return section
    }

    private static func loadNativeLyricsSectionIndex() -> Int? {
        contextLock.lock()
        if let index = nativeLyricsSectionIndex {
            contextLock.unlock()
            return index
        }
        contextLock.unlock()

        guard UserDefaults.standard.object(forKey: nativeIndexDefaultsKey) != nil else {
            return nil
        }
        let index = max(0, UserDefaults.standard.integer(forKey: nativeIndexDefaultsKey))
        contextLock.lock()
        nativeLyricsSectionIndex = index
        contextLock.unlock()
        return index
    }

    private static func lyricsSection(
        from template: [UInt8],
        trackURI: String,
        sectionURI: String
    ) -> [UInt8]? {
        guard let fields = parseFields(template, in: 0..<template.count),
              let lyricsField = fields.first(where: {
                  $0.number == lyricsFieldNumber && $0.wireType == 2
              }),
              let lyricsStart = lyricsField.payloadStart,
              let lyricsEnd = lyricsField.payloadEnd
        else { return nil }

        let lyricsPayload = Array(template[lyricsStart..<lyricsEnd])
        guard let rewrittenLyrics = replacingLengthDelimitedField(
            in: lyricsPayload,
            number: 1,
            payload: Array(trackURI.utf8)
        ) else { return nil }

        guard let rewrittenSection = replacingLengthDelimitedField(
            in: template,
            number: lyricsFieldNumber,
            payload: rewrittenLyrics
        ),
              let rewrittenFields = parseFields(
                  rewrittenSection,
                  in: 0..<rewrittenSection.count
              ),
              let sectionInfoField = rewrittenFields.first(where: {
                  ($0.number == sectionInfoFieldNumber || $0.number == 39)
                      && $0.wireType == 2
              }),
              let sectionInfoStart = sectionInfoField.payloadStart,
              let sectionInfoEnd = sectionInfoField.payloadEnd,
              let rewrittenInfo = replacingLengthDelimitedField(
                  in: Array(rewrittenSection[sectionInfoStart..<sectionInfoEnd]),
                  number: 1,
                  payload: Array(sectionURI.utf8)
              ) else {
            return nil
        }

        return replacingLengthDelimitedField(
            in: rewrittenSection,
            number: sectionInfoField.number,
            payload: rewrittenInfo
        )
    }

    private static func replacingLengthDelimitedField(
        in bytes: [UInt8],
        number: Int,
        payload: [UInt8]
    ) -> [UInt8]? {
        guard let fields = parseFields(bytes, in: 0..<bytes.count),
              let field = fields.first(where: { $0.number == number && $0.wireType == 2 })
        else { return nil }

        var replacement = [UInt8]()
        appendMessageField(number: number, payload: payload, to: &replacement)

        var result = Array(bytes[..<field.fieldStart])
        result.append(contentsOf: replacement)
        result.append(contentsOf: bytes[field.fieldEnd...])
        return result
    }

    private static func newStructureInsertionOffset(
        structureFields: [WireField],
        structureStart: Int,
        structureEnd: Int
    ) -> Int {
        guard let firstField = structureFields.first else { return 0 }
        return min(firstField.fieldStart - structureStart, structureEnd - structureStart)
    }

    private static func trackIDFromLyricsPath(_ path: String) -> String? {
        guard let marker = path.range(of: "/track/", options: .caseInsensitive) else {
            return nil
        }
        let candidate = path[marker.upperBound...].prefix { $0.isLetter || $0.isNumber }
        let trackID = String(candidate)
        return isSpotifyTrackID(trackID) ? trackID : nil
    }

    private static func embeddedTrackID(in bytes: [UInt8]) -> String? {
        guard bytes.count >= spotifyTrackPrefix.count + 22 else { return nil }

        var index = 0
        while index + spotifyTrackPrefix.count + 22 <= bytes.count {
            if bytes[index..<(index + spotifyTrackPrefix.count)].elementsEqual(spotifyTrackPrefix) {
                let idStart = index + spotifyTrackPrefix.count
                let idEnd = idStart + 22
                let trackID = String(decoding: bytes[idStart..<idEnd], as: UTF8.self)
                if isSpotifyTrackID(trackID) {
                    return trackID
                }
            }
            index += 1
        }
        return nil
    }

    private static func isSpotifyTrackID(_ value: String) -> Bool {
        value.utf8.count == 22 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
        }
    }

    private static func parseFields(_ bytes: [UInt8], in range: Range<Int>) -> [WireField]? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }

        var fields = [WireField]()
        var cursor = range.lowerBound

        while cursor < range.upperBound {
            let fieldStart = cursor
            guard let key = readVarint(bytes, cursor: &cursor, limit: range.upperBound) else {
                return nil
            }

            let number = Int(key >> 3)
            let wireType = UInt8(key & 0x07)
            guard number > 0 else { return nil }

            var lengthStart: Int?
            var payloadStart: Int?
            var payloadEnd: Int?

            switch wireType {
            case 0:
                guard readVarint(bytes, cursor: &cursor, limit: range.upperBound) != nil else {
                    return nil
                }
            case 1:
                guard cursor <= range.upperBound - 8 else { return nil }
                cursor += 8
            case 2:
                lengthStart = cursor
                guard let length = readVarint(bytes, cursor: &cursor, limit: range.upperBound),
                      length <= UInt64(Int.max),
                      Int(length) <= range.upperBound - cursor else {
                    return nil
                }
                payloadStart = cursor
                cursor += Int(length)
                payloadEnd = cursor
            case 5:
                guard cursor <= range.upperBound - 4 else { return nil }
                cursor += 4
            default:
                // Groups are not used by the Scrollsita schema. Reject them
                // instead of attempting an ambiguous rewrite.
                return nil
            }

            fields.append(WireField(
                number: number,
                wireType: wireType,
                fieldStart: fieldStart,
                lengthStart: lengthStart,
                payloadStart: payloadStart,
                payloadEnd: payloadEnd,
                fieldEnd: cursor
            ))
        }

        return fields
    }

    private static func readVarint(
        _ bytes: [UInt8],
        cursor: inout Int,
        limit: Int
    ) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0

        for _ in 0..<10 where cursor < limit {
            let byte = bytes[cursor]
            cursor += 1

            if shift == 63 && (byte & 0xfe) != 0 { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if (byte & 0x80) == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func appendStringField(number: Int, value: String, to output: inout [UInt8]) {
        appendMessageField(number: number, payload: Array(value.utf8), to: &output)
    }

    private static func appendMessageField(number: Int, payload: [UInt8], to output: inout [UInt8]) {
        output.append(contentsOf: encodeVarint(UInt64((number << 3) | 2)))
        output.append(contentsOf: encodeVarint(UInt64(payload.count)))
        output.append(contentsOf: payload)
    }

    private static func encodeVarint(_ input: UInt64) -> [UInt8] {
        var value = input
        var result = [UInt8]()
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            result.append(byte)
        } while value != 0
        return result
    }
}
