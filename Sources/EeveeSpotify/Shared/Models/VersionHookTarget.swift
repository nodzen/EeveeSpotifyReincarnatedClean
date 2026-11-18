/// Selects which hook set to activate for the running Spotify build.
///
/// Version -> target mapping (see `EeveeSpotify.hookTarget`):
/// - Spotify 8.9.8  (last build for iOS 14) -> .lastAvailableiOS14
/// - Spotify 9.0.48 (last build for iOS 15) -> .lastAvailableiOS15
/// - Spotify 9.1.x and every later release   -> .v91
/// - Anything older                           -> .v90
///
/// Rule for new code: branch on this enum in ONE place per feature
/// (targetName switch or a single `hookTarget ==` check in Tweak.x.swift).
/// Never match raw version strings outside `hookTarget`.
enum VersionHookTarget {
    /// Spotify 9.0.x and earlier, apart from the pinned builds below.
    case v90
    /// Spotify 9.0.48: last build that runs on iOS 15.
    case lastAvailableiOS15
    /// Spotify 9.1.x and later.
    case v91
    /// Spotify 8.9.8: last build that runs on iOS 14.
    case lastAvailableiOS14

    // Every release from 9.1 on uses the 9.1 hooks; a string match on "9.1"
    // sent 9.2.0 down the 9.0 path, which never activates Premium.
    static func forSpotifyVersion(_ version: String) -> VersionHookTarget {
        switch version {
        case "9.0.48":
            return .lastAvailableiOS15
        case "8.9.8":
            return .lastAvailableiOS14
        default:
            break
        }

        // An unreadable version is far more likely a current build than a 9.0 one.
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else {
            return .v91
        }

        if major > 9 || (major == 9 && minor >= 1) {
            return .v91
        }
        return .v90
    }
}
