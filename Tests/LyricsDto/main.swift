import Foundation

// Minimal protobuf/settings adapters; the conversion under test is production code.
protocol Builder { init() }
extension Builder {
    static func with(_ body: (inout Self) -> Void) -> Self {
        var value = Self(); body(&value); return value
    }
}
enum Restriction { case unrestricted }
struct LyricsLine: Builder { var content = ""; var offsetMs: Int32 = 0 }
struct LyricsTranslation: Builder { var languageCode = ""; var lines: [String] = [] }
struct LyricsData: Builder {
    var timeSynchronized = false
    var restriction = Restriction.unrestricted
    var providedBy = ""
    var lines: [LyricsLine] = []
    var translation = LyricsTranslation()
}
struct Options { var romanization = false; var hideOnError = false }
extension UserDefaults { static var lyricsOptions = Options() }
extension String { var localized: String { self } }

func convert(_ offsets: [Int?], synced: Bool) -> LyricsData {
    LyricsDto(lines: offsets.enumerated().map {
        LyricsLineDto(content: "line\($0.offset)", offsetMs: $0.element)
    }, timeSynced: synced, romanization: .original).toSpotifyLyricsData(source: "test")
}
let partial = convert([1000, nil, 3000], synced: true)
precondition(!partial.timeSynchronized)
precondition(partial.lines.map(\.content) == ["line0", "line1", "line2"])
precondition(partial.lines.allSatisfy { $0.offsetMs == 0 })
precondition(!convert([0, 0], synced: true).timeSynchronized)
precondition(!convert([-1, 1000], synced: true).timeSynchronized)
let valid = convert([3000, 1000, 2000], synced: true)
precondition(valid.timeSynchronized)
precondition(valid.lines.map(\.offsetMs) == [1000, 2000, 3000])
let plain = convert([3000, 1000], synced: false)
precondition(plain.lines.map(\.content) == ["line0", "line1"])
precondition(plain.lines.allSatisfy { $0.offsetMs == 0 })
// Empty result + hideOnError: no lines at all, instead of the not-found text.
UserDefaults.lyricsOptions.hideOnError = true
precondition(convert([], synced: false).lines.isEmpty)
UserDefaults.lyricsOptions.hideOnError = false
precondition(!convert([], synced: false).lines.isEmpty)
// Instrumental is an answer, not a failure: its message renders even when the
// not-found text is suppressed, so the card can say what the track is.
UserDefaults.lyricsOptions.hideOnError = true
precondition(!LyricsDto.instrumental.toSpotifyLyricsData(source: "test").lines.isEmpty)
precondition(LyricsDto.instrumental.lines.first?.content == "song_is_instrumental")
UserDefaults.lyricsOptions.hideOnError = false
print("Lyrics timing conversion tests passed")
