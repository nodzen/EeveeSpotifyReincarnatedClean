import Foundation

/// Dedicated analytics uploads are isolated from Spotify's authenticated
/// Event Sender. The latter also carries playback, offline and royalty data,
/// so it must remain available for normal account behavior.
enum AnalyticsNetworkPolicy {
    static func shouldCancel(_ url: URL) -> Bool {
        UserDefaults.blockSpotifyAnalytics && url.isSpotifyAnalyticsRelated
    }
}
