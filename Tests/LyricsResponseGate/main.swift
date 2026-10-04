import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let firstSession = URLSession(configuration: .ephemeral)
let secondSession = URLSession(configuration: .ephemeral)
let firstURL = URL(string: "https://example.com/track/A")!
let secondURL = URL(string: "https://example.com/track/B")!
let first = firstSession.dataTask(with: firstURL)
let second = secondSession.dataTask(with: secondURL)
let ok = HTTPURLResponse(url: firstURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
let missing = HTTPURLResponse(url: secondURL, statusCode: 404, httpVersion: nil, headerFields: nil)!
expect(first.taskIdentifier == second.taskIdentifier, "Exercise equal IDs across sessions")
LyricsResponseGate.hold(ok, for: first)
LyricsResponseGate.hold(missing, for: second)
expect(LyricsResponseGate.take(for: second)?.url == secondURL, "B must retain its own response")
expect(LyricsResponseGate.take(for: first)?.statusCode == 200, "A must retain its native response")
expect(LyricsResponseGate.take(for: first) == nil, "Completion must consume once")
firstSession.invalidateAndCancel()
secondSession.invalidateAndCancel()
print("Lyrics response identity tests passed")
