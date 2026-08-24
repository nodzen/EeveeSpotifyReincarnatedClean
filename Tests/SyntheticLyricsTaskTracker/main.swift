import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

let tracker = SyntheticLyricsTaskTracker()
let url = URL(string: "https://example.com/color-lyrics/v2/track/test")!
let first = URLSession.shared.dataTask(with: url)
let second = URLSession.shared.dataTask(with: url)

expect(!tracker.consume(first), "an unmarked task must not be consumed")

tracker.mark(first)
expect(tracker.consume(first), "a marked task must be consumed once")
expect(!tracker.consume(first), "a task must not be consumed twice")

tracker.mark(first)
tracker.mark(second)
expect(tracker.consume(second), "task identity must keep concurrent tasks separate")
expect(tracker.consume(first), "consuming another task must not remove this one")

print("Synthetic lyrics task tracker tests passed")
