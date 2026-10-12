/// Selects which hook set to activate for the running Spotify build.
///
/// Version -> target mapping (see `EeveeSpotify.hookTarget`):
/// - Spotify 8.9.8  (last build for iOS 14) -> .lastAvailableiOS14
/// - Spotify 9.0.48 (last build for iOS 15) -> .lastAvailableiOS15
/// - Spotify 9.1.x  (current family)        -> .v91
/// - Anything else (older or newer)         -> .latest (forward-compatible)
///
/// Rule for new code: branch on this enum in ONE place per feature
/// (targetName switch or a single `hookTarget ==` check in Tweak.x.swift).
/// Never match raw version strings outside `hookTarget`.
enum VersionHookTarget {
    /// Unknown/older/newer Spotify. Gets the modern hook set.
    case latest
    /// Spotify 9.0.48: last build that runs on iOS 15.
    case lastAvailableiOS15
    /// Spotify 9.1.x versions.
    case v91 // Spotify 9.1.x versions
    /// Spotify 8.9.8: last build that runs on iOS 14.
    case lastAvailableiOS14
}
