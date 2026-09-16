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
///      -> Section.section_info (#39)
///
/// The field numbers were verified against Spotify 9.1.80's generated
/// `Spotify_Scrollsita_V1_*` message implementations. Existing fields remain
/// byte-for-byte unchanged.
enum ScrollsitaLyricsCardPatcher {
    private static let lyricsFieldNumber = 5
    private static let sectionInfoFieldNumber = 39

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
    private static var latestLyricsTrack: (id: String, timestamp: Date)?
    private static let spotifyTrackPrefix = Array("spotify:track:".utf8)

    static func shouldHandle(_ url: URL) -> Bool {
        url.path.lowercased().contains("/scrollsita/")
    }

    /// Called as soon as a color-lyrics task is resumed/observed. This gives
    /// the parallel Scrollsita request the exact current track even when its
    /// URL does not expose the entity URI.
    static func noteLyricsRequest(_ url: URL) {
        guard url.isLyrics, let trackID = trackIDFromLyricsPath(url.path) else {
            return
        }

        storeTrackID(trackID)
    }

    /// Spotify 9.1.80's `ScrollsitaRequest` carries `entityUri`. Capture it
    /// from the outgoing URL or protobuf body so the lower card also works
    /// when the user has disabled the independent under-cover lyrics surface
    /// and no color-lyrics request has started yet.
    static func noteScrollsitaRequest(_ request: URLRequest) {
        guard let url = request.url, shouldHandle(url) else { return }

        let decodedURL = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let trackID = embeddedTrackID(in: Array(decodedURL.utf8))
            ?? request.httpBody.flatMap { embeddedTrackID(in: [UInt8]($0)) }
        guard let trackID else { return }

        storeTrackID(trackID)
    }

    private static func storeTrackID(_ trackID: String) {
        guard isSpotifyTrackID(trackID) else { return }

        contextLock.lock()
        latestLyricsTrack = (trackID, Date())
        contextLock.unlock()
    }

    /// Returns a modified response only when the server omitted the lyrics
    /// section and an exact/recent track ID is available.
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

        for sectionField in structureFields where sectionField.number == 1 && sectionField.wireType == 2 {
            guard let sectionStart = sectionField.payloadStart,
                  let sectionEnd = sectionField.payloadEnd,
                  let sectionFields = parseFields(bytes, in: sectionStart..<sectionEnd)
            else { continue }

            if sectionFields.contains(where: {
                $0.number == lyricsFieldNumber && $0.wireType == 2
            }) {
                writeDebugLog("[ScrollsitaLyrics] native lyrics section already present path=\(url.path)")
                return nil
            }
        }

        let trackID = embeddedTrackID(in: bytes)
            ?? embeddedTrackID(in: Array((url.absoluteString.removingPercentEncoding ?? url.absoluteString).utf8))
            ?? recentLyricsTrackID()

        guard let trackID = trackID else {
            writeDebugLog("[ScrollsitaLyrics] skipped injection: current track ID unavailable path=\(url.path)")
            return nil
        }

        let trackURI = "spotify:track:\(trackID)"

        // SectionInfo.section_id (#1). Keep it stable for this track so the
        // diffable data source sees one deterministic card identifier.
        var sectionInfo = [UInt8]()
        appendStringField(number: 1, value: "eevee-lyrics-\(trackID)", to: &sectionInfo)

        // Lyrics.entity_uri (#1).
        var lyrics = [UInt8]()
        appendStringField(number: 1, value: trackURI, to: &lyrics)

        // Spotify 9.1.80 models the section body as a oneof. Lyrics is case
        // field #5; field #6 is merch. SectionInfo is the separate field #39.
        var section = [UInt8]()
        appendMessageField(number: lyricsFieldNumber, payload: lyrics, to: &section)
        appendMessageField(number: sectionInfoFieldNumber, payload: sectionInfo, to: &section)

        // Append one NpvScrollStructure.sections (#1) entry, preserving every
        // server-provided section and its ordering.
        var newStructure = Array(bytes[structureStart..<structureEnd])
        appendMessageField(number: 1, payload: section, to: &newStructure)

        guard let lengthStart = structureField.lengthStart else { return nil }
        var result = Array(bytes[..<lengthStart])
        result.append(contentsOf: encodeVarint(UInt64(newStructure.count)))
        result.append(contentsOf: newStructure)
        result.append(contentsOf: bytes[structureField.fieldEnd...])

        writeDebugLog("[ScrollsitaLyrics] injected lower lyrics card schema=lyrics#5/info#39 track=\(trackID) \(data.count)->\(result.count)")
        return Data(result)
    }

    private static func recentLyricsTrackID() -> String? {
        contextLock.lock()
        defer { contextLock.unlock() }

        guard let context = latestLyricsTrack,
              Date().timeIntervalSince(context.timestamp) <= 15 else {
            return nil
        }
        return context.id
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
