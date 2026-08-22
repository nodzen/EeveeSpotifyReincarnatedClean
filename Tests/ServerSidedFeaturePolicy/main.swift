import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

let protectedAttributes = ServerSidedFeaturePolicy.serverAuthoritativeAccountAttributes
for name in [
    "offline",
    "audio-quality",
    "social-session",
    "social-session-free-tier",
    "jam-social-session",
] {
    require(protectedAttributes.contains(name), "missing server-authoritative attribute: \(name)")
}

require(
    !ServerSidedFeaturePolicy.shouldOverwriteResolvedConfiguration(
        requested: true,
        isSpotify91: true
    ),
    "Spotify 9.1.x must retain its live resolve configuration"
)
require(
    ServerSidedFeaturePolicy.shouldOverwriteResolvedConfiguration(
        requested: true,
        isSpotify91: false
    ),
    "explicit overwrite must remain available for compatible legacy builds"
)
require(
    !ServerSidedFeaturePolicy.shouldOverwriteResolvedConfiguration(
        requested: false,
        isSpotify91: false
    ),
    "disabled overwrite must retain the live configuration"
)

require(
    ServerSidedFeaturePolicy.premiumGatedJamEntryPoint == .init(
        scope: "ios-sociallistening-configuration-impl",
        name: "premium_gated_start_jam_buttons_enabled"
    ),
    "Premium-gated Jam entry point changed unexpectedly"
)

print("Server-sided feature policy tests passed")
