import Foundation

/// Decides which response bodies may be suppressed. This is deliberately
/// separate from SpotifyResponsePatcher: patching valid protobuf responses and
/// cancelling unwanted requests are different operations with different risks.
enum SpotifyResponseBlockPolicy {
    static func shouldBlock(_ url: URL) -> Bool {
        if url.isSessionInvalidation || url.isAdRelated {
            return true
        }

        // The former implementation also replaced configuration, signup and
        // account-state responses after 30 seconds. Keep that behavior only as
        // an opt-in diagnostic compatibility mode; it is not safe for release.
        return EeveeDebug.legacyResponseBlocksEnabled && legacyShouldBlock(url)
    }

    static func responseData(for url: URL) -> Data {
        if EeveeDebug.legacyResponseBlocksEnabled, let legacy = legacyResponseData(for: url) {
            return legacy
        }

        if url.isSessionInvalidation {
            return Data(#"{"status":"OK"}"#.utf8)
        }

        // Premium marketing is JSON, while most ad containers are consumed as
        // optional binary/protobuf bodies. Keep their safe empty response.
        if url.isPremiumMarketing {
            return Data("{}".utf8)
        }
        return Data()
    }

    private static func legacyShouldBlock(_ url: URL) -> Bool {
        let elapsed = Date().timeIntervalSince(tweakInitTime)
        guard elapsed > 30 else { return false }

        let path = url.path.lowercased()
        return url.isAccountValidate || url.isOndemandSelector
            || url.isTrialsFacade || url.isPremiumMarketing || url.isPendragonFetchMessageList
            || url.isPushkaTokens
            || path.contains("signup/public")
            || path.contains("apresolve")
            || path.contains("pses/screenconfig")
            || path.contains("v1/customize")
    }

    private static func legacyResponseData(for url: URL) -> Data? {
        guard legacyShouldBlock(url) else { return nil }

        let path = url.path.lowercased()
        if url.isAccountValidate {
            return Data(#"{"status":1,"country":"US","is_country_launched":true}"#.utf8)
        }
        if url.isTrialsFacade {
            return Data(#"{"result":"NOT_ELIGIBLE"}"#.utf8)
        }
        if url.isPremiumMarketing {
            return Data("{}".utf8)
        }
        if path.contains("signup/public") || path.contains("apresolve") {
            return Data(#"{"status":"OK"}"#.utf8)
        }
        if path.contains("pses/screenconfig") {
            return Data("{}".utf8)
        }
        if path.contains("v1/customize"),
           let cached = SpotifyResponsePatcher.cachedCustomizeData {
            return cached
        }
        return Data()
    }
}
