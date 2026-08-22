import Foundation

/// Tracks URLSession tasks for which a non-200 Spotify lyrics response was
/// replaced with a synthetic 200 response and custom body.
final class SyntheticLyricsTaskTracker {
    private let lock = NSLock()
    private var tasks = Set<ObjectIdentifier>()

    func mark(_ task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        tasks.insert(ObjectIdentifier(task))
    }

    /// Returns true exactly once for each marked task.
    func consume(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks.remove(ObjectIdentifier(task)) != nil
    }
}
