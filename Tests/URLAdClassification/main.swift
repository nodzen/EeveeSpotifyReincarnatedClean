import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func url(_ value: String) -> URL {
    URL(string: value)!
}

require(url("https://spclient.wg.spotify.com/premium-upsell/banner").isAdRelated,
        "Premium upsell banner endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/premium-marketing/upsellOffer").isAdRelated,
        "Premium marketing offer endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/premium-marketing/upselloffer").isAdRelated,
        "Premium marketing offer endpoint must be case-insensitive")
require(url("https://spclient.wg.spotify.com/referrals/upsell/card").isAdRelated,
        "referral upsell card endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/ads/ad-on-app-open").isAdRelated,
        "home ad-on-app-open endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/esperanto/v1/ad-slots").isAdRelated,
        "Esperanto ad-slot endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/dac/view/v1/home").isAdRelated,
        "home/search display-ad endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/leavebehind").isAdRelated,
        "leave-behind endpoint without a trailing slash must be blocked")
require(url("https://doubleclick.net/v1/content").isAdRelated,
        "known ad hosts must be blocked")
require(!url("https://spclient.wg.spotify.com/collection/v1/library/items").isAdRelated,
        "ordinary library endpoint must not be blocked")
require(!url("https://lyrics.example.com/banner/v1/track").isAdRelated,
        "generic ad-shaped paths on external lyrics hosts must remain available")

require(url("https://firebaselogging.googleapis.com/v0cc/log").isSpotifyAnalyticsRelated,
        "Firebase logging endpoint must be blocked")
require(url("https://firebase-settings.crashlytics.com/spi/v2/platforms/ios").isSpotifyAnalyticsRelated,
        "Crashlytics settings endpoint must be blocked")
require(url("https://api-safetrack-eu.branch.io/v1/event").isSpotifyAnalyticsRelated,
        "Branch safetrack endpoint must be blocked")
require(url("https://census-app.scorecardresearch.com/p2").isSpotifyAnalyticsRelated,
        "ComScore endpoint must be blocked")
require(url("https://www.googleadservices.com/pagead/conversion/app/deeplink").isSpotifyAnalyticsRelated,
        "Google ad attribution endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/gabo-receiver-service/public/v3/events").isSpotifyAnalyticsRelated,
        "anonymous Spotify event endpoint must be blocked")

require(!url("https://api3.branch.io/v1/open").isSpotifyAnalyticsRelated,
        "Branch deep-link resolution must remain available")
require(!url("https://login5.spotify.com/v4/login").isSpotifyAnalyticsRelated,
        "Spotify login must remain available")
require(!url("https://spclient.wg.spotify.com/gabo-receiver-service/v3/events").isSpotifyAnalyticsRelated,
        "authenticated core Event Sender must remain available")
require(!url("https://spclient.wg.spotify.com/audio/track").isSpotifyAnalyticsRelated,
        "Spotify content endpoint must remain available")

require(url("https://spclient.wg.spotify.com/account/DeleteToken").isSessionInvalidation,
        "DeleteToken must remain protected")
require(url("https://spclient.wg.spotify.com/session/purge").isSessionInvalidation,
        "session purge must remain protected")
require(url("https://accounts.spotify.com/logout").isExplicitLogoutEndpoint,
        "manual logout must be recognized for diagnostics")
require(!url("https://spclient.wg.spotify.com/product-state/update").isSessionInvalidation,
        "product-state must not be treated as logout")
require(!url("https://spclient.wg.spotify.com/license/check").isSessionInvalidation,
        "license check must not be treated as logout")
require(!url("https://login5.spotify.com/auth/expire").isSessionInvalidation,
        "auth expiry must not be treated as logout")

// ClientMessagingPlatform message fetches (9.1.84 win-back fullscreen, Home
// Premium banner). The RPC set was renamed from FetchMessageList to
// FetchMessage / FetchMessageForPreview; all must stay blocked.
require(url("https://spclient.wg.spotify.com/pendragon/v1/FetchMessageList").isPendragonFetchMessageList,
        "legacy pendragon FetchMessageList must be blocked")
require(url("https://spclient.wg.spotify.com/pendragon/v1/FetchMessage").isPendragonFetchMessageList,
        "9.1.84 pendragon FetchMessage must be blocked")
require(url("https://spclient.wg.spotify.com/pendragon/v1/FetchMessageForPreview").isPendragonFetchMessageList,
        "pendragon FetchMessageForPreview must be blocked")
require(!url("https://spclient.wg.spotify.com/pendragon/v1/AcknowledgeMessage").isPendragonFetchMessageList,
        "non-fetch pendragon RPCs must not be blocked")
require(!url("https://spclient.wg.spotify.com/decipher/agent/v1/FetchMessage").isPendragonFetchMessageList,
        "non-pendragon FetchMessage paths must not be blocked")

print("URL ad classification regression tests passed")
