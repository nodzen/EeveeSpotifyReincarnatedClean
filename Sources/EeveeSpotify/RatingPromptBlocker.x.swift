// Blocks the App Store "Enjoying Spotify?" rating prompt by no-op'ing
// SKStoreReviewController requestReview entry points at launch.

import Orion
import StoreKit

struct RatingPromptBlockerGroup: HookGroup {}

class StoreReviewRequestHook: ClassHook<SKStoreReviewController> {
    typealias Group = RatingPromptBlockerGroup

    class func requestReview() {
        RatingPromptBlocker.blocked("requestReview")
    }

    class func requestReviewInScene(_ scene: UIWindowScene) {
        RatingPromptBlocker.blocked("requestReviewInScene(_:)")
    }
}

enum RatingPromptBlocker {
    static let launchEnabled = UserDefaults.blockRatingPrompts
    private static var count = 0

    static func blocked(_ method: String) {
        count += 1
        NSLog("[EeveeSpotify] Blocked rating prompt (%@, %d total)", method, count)
        writeDebugLog("[PRIVACY] Blocked rating prompt (\(method), \(count) total)")
    }
}

func activateRatingPromptBlocker() {
    guard RatingPromptBlocker.launchEnabled else { return }
    RatingPromptBlockerGroup().activate()
    NSLog("[EeveeSpotify] Rating prompt blocker activated")
}
