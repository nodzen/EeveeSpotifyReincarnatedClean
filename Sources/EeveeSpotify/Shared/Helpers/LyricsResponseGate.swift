import Foundation

/// Drain the native HTTP body before publishing the response to Spotify.
/// This preserves native colors without starting its lyrics renderer early.
/// Keys are task objects, since taskIdentifier is only unique per session.
enum LyricsResponseGate {
    private static let lock = NSLock()
    private static var responses: [ObjectIdentifier: HTTPURLResponse] = [:]

    static func hold(_ response: HTTPURLResponse, for task: URLSessionTask) {
        lock.lock()
        responses[ObjectIdentifier(task)] = response
        lock.unlock()
    }

    static func take(for task: URLSessionTask) -> HTTPURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses.removeValue(forKey: ObjectIdentifier(task))
    }
}
