import Foundation

func writeDebugLog(_ message: String) {}

extension URL {
    var isLyrics: Bool {
        path.lowercased().contains("/color-lyrics/")
    }
}

private struct Field {
    let number: Int
    let payload: Data?
    let encoded: Data
}

private func varint(_ input: UInt64) -> Data {
    var value = input
    var result = Data()
    repeat {
        var byte = UInt8(value & 0x7f)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        result.append(byte)
    } while value != 0
    return result
}

private func lengthDelimited(_ number: Int, _ payload: Data) -> Data {
    var result = varint(UInt64((number << 3) | 2))
    result.append(varint(UInt64(payload.count)))
    result.append(payload)
    return result
}

private func string(_ number: Int, _ value: String) -> Data {
    lengthDelimited(number, Data(value.utf8))
}

private func readVarint(_ data: Data, _ cursor: inout Int) -> UInt64? {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    for _ in 0..<10 where cursor < data.count {
        let byte = data[cursor]
        cursor += 1
        if shift == 63 && (byte & 0xfe) != 0 { return nil }
        value |= UInt64(byte & 0x7f) << shift
        if (byte & 0x80) == 0 { return value }
        shift += 7
    }
    return nil
}

private func fields(_ data: Data) -> [Field]? {
    var result = [Field]()
    var cursor = 0
    while cursor < data.count {
        let start = cursor
        guard let key = readVarint(data, &cursor) else { return nil }
        let number = Int(key >> 3)
        switch key & 7 {
        case 0:
            guard readVarint(data, &cursor) != nil else { return nil }
            result.append(Field(number: number, payload: nil, encoded: data.subdata(in: start..<cursor)))
        case 2:
            guard let length = readVarint(data, &cursor),
                  length <= UInt64(data.count - cursor) else { return nil }
            let end = cursor + Int(length)
            result.append(Field(
                number: number,
                payload: data.subdata(in: cursor..<end),
                encoded: data.subdata(in: start..<end)
            ))
            cursor = end
        default:
            return nil
        }
    }
    return result
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func response(sections: [Data], trailing: Data = Data()) -> Data {
    let structure = sections.reduce(into: Data()) { result, section in
        result.append(lengthDelimited(1, section))
    }
    var result = lengthDelimited(1, structure)
    result.append(trailing)
    return result
}

private func section(id: String, lyricsTrackID: String? = nil, marker: String? = nil) -> Data {
    var value = lengthDelimited(39, string(1, id))
    if let lyricsTrackID {
        value.append(lengthDelimited(5, string(1, "spotify:track:\(lyricsTrackID)")))
    }
    if let marker {
        value.append(string(50, marker))
    }
    return value
}

private func decodedSections(_ response: Data) -> [Data]? {
    guard let structure = fields(response)?.first(where: { $0.number == 1 })?.payload else {
        return nil
    }
    return fields(structure)?.filter { $0.number == 1 }.compactMap(\.payload)
}

private let trackID = "5ET9lyWJbupwVpNsSxQe3b"
private let anotherTrackID = "2iCyV71yTK9z7HIYJjkQHr"
private let scrollURL = URL(string: "https://spclient.wg.spotify.com/scrollsita/v1/npv")!
private let nonScrollURL = URL(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackID)")!

require(ScrollsitaLyricsCardPatcher.shouldHandle(scrollURL), "Scrollsita responses must be inspected")
require(!ScrollsitaLyricsCardPatcher.shouldHandle(nonScrollURL), "unrelated responses must stay untouched")

let ordinarySection = section(id: "queue", marker: "spotify:track:\(trackID)")
let responseSuffix = string(3, "debug-info-must-survive")
let original = response(sections: [ordinarySection], trailing: responseSuffix)
guard let injected = ScrollsitaLyricsCardPatcher.injectLyricsSectionIfMissing(original, url: scrollURL),
      let injectedSections = decodedSections(injected) else {
    fatalError("FAIL: missing lyrics section was not injected")
}

require(injectedSections.count == 2, "exactly one section must be appended")
require(injectedSections[0] == ordinarySection, "existing sections must remain byte-for-byte unchanged")
require(injected.suffix(responseSuffix.count) == responseSuffix, "top-level fields after structure must survive")

private let addedFields = fields(injectedSections[1])
private let addedInfo = addedFields?.first(where: { $0.number == 39 })?.payload.flatMap(fields)
private let addedLyrics = addedFields?.first(where: { $0.number == 5 })?.payload.flatMap(fields)
require(addedInfo?.first(where: { $0.number == 1 })?.payload == Data("eevee-lyrics-\(trackID)".utf8),
        "injected section needs a deterministic section ID")
require(addedLyrics?.first(where: { $0.number == 1 })?.payload == Data("spotify:track:\(trackID)".utf8),
        "injected lyrics entity URI must match the current track")
require(addedFields?.contains(where: { $0.number == 1 || $0.number == 6 }) == false,
        "injected section must not use comments (#1) or merch (#6) fields")
require(ScrollsitaLyricsCardPatcher.injectLyricsSectionIfMissing(injected, url: scrollURL) == nil,
        "patching must be idempotent")

let native = response(sections: [section(id: "lyrics", lyricsTrackID: trackID)])
require(ScrollsitaLyricsCardPatcher.injectLyricsSectionIfMissing(native, url: scrollURL) == nil,
        "a native lyrics section must never be duplicated")

var merch = section(id: "merch")
merch.append(lengthDelimited(6, string(1, "spotify:track:\(trackID)")))
let merchOnly = response(sections: [merch])
guard let merchPatched = ScrollsitaLyricsCardPatcher.injectLyricsSectionIfMissing(merchOnly, url: scrollURL),
      let merchPatchedSections = decodedSections(merchPatched) else {
    fatalError("FAIL: merch field #6 was mistaken for a native lyrics section")
}
require(merchPatchedSections.count == 2,
        "a merch section must not suppress external lyrics")
require(fields(merchPatchedSections[1])?.contains(where: { $0.number == 5 }) == true,
        "lyrics must use Scrollsita oneof field #5")

var scrollRequest = URLRequest(url: scrollURL)
scrollRequest.httpBody = string(1, "spotify:track:\(anotherTrackID)")
ScrollsitaLyricsCardPatcher.noteScrollsitaRequest(scrollRequest)
let scrollRequestOnly = response(sections: [section(id: "queue")])
guard let requestInjected = ScrollsitaLyricsCardPatcher.injectLyricsSectionIfMissing(scrollRequestOnly, url: scrollURL),
      let requestLyricsSection = decodedSections(requestInjected)?.last,
      let requestLyricsMessage = fields(requestLyricsSection)?.first(where: { $0.number == 5 })?.payload,
      let requestEntity = fields(requestLyricsMessage)?.first(where: { $0.number == 1 })?.payload else {
    fatalError("FAIL: Scrollsita request body did not supply current track context")
}
require(requestEntity == Data("spotify:track:\(anotherTrackID)".utf8),
        "Scrollsita request context must preserve the exact track ID")

let contextURL = URL(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(anotherTrackID)?format=json")!
ScrollsitaLyricsCardPatcher.noteLyricsRequest(contextURL)
let contextOnly = response(sections: [section(id: "queue")])
guard let contextInjected = ScrollsitaLyricsCardPatcher.injectLyricsSectionIfMissing(contextOnly, url: scrollURL),
      let contextLyricsSection = decodedSections(contextInjected)?.last,
      let contextLyricsMessage = fields(contextLyricsSection)?.first(where: { $0.number == 5 })?.payload,
      let contextEntity = fields(contextLyricsMessage)?.first(where: { $0.number == 1 })?.payload else {
    fatalError("FAIL: recent color-lyrics request did not supply Scrollsita track context")
}
require(contextEntity == Data("spotify:track:\(anotherTrackID)".utf8),
        "request context must preserve the exact track ID")

require(ScrollsitaLyricsCardPatcher.injectLyricsSectionIfMissing(Data([0x0a, 0xff]), url: scrollURL) == nil,
        "malformed protobuf must fail closed")

print("ScrollsitaLyricsCardPatcher regression tests passed")
