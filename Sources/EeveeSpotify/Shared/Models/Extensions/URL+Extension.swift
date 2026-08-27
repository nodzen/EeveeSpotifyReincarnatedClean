import Foundation

extension URL {
    var isLyrics: Bool {
        self.path.contains("color-lyrics/v2")
    }
    
    var isPlanOverview: Bool {
        self.path.contains("GetPlanOverview")
    }
    
    var isShuffle: Bool {
        self.path.contains("shuffle")
    }
    
    var isPremiumPlanRow: Bool {
        self.path.contains("v1/GetPremiumPlanRow")
    }
    
    var isPremiumBadge: Bool {
        self.path.contains("GetYourPremiumBadge")
    }

    var isOpenSpotifySafariExtension: Bool {
        self.host == "eevee"
    }
    
    var isCustomize: Bool {
        self.path.contains("v1/customize")
    }
    
    var isBootstrap: Bool {
        self.path.contains("v1/bootstrap")
    }

    // Blocked endpoint matchers (session protection)

    var isDeleteToken: Bool {
        self.path.lowercased().contains("deletetoken")
    }

    var isAccountValidate: Bool {
        self.path.contains("signup/public")
    }

    var isOndemandSelector: Bool {
        self.path.contains("select-ondemand-set")
    }

    var isTrialsFacade: Bool {
        self.path.contains("trials-facade/start-trial")
    }

    var isPremiumMarketing: Bool {
        self.path.lowercased().contains("premium-marketing/upselloffer")
    }

    var isPendragonFetchMessageList: Bool {
        self.path.contains("pendragon") && self.path.contains("FetchMessageList")
    }

    var isPushkaTokens: Bool {
        self.path.contains("pushka-tokens")
    }
    
    var isAdRelated: Bool {
        let path = self.path.lowercased()
        let host = (self.host ?? "").lowercased()

        // The Premium marketing offer is a JSON upsell, not a regular ad
        // container. Keep it in the production blocking policy as well.
        if isPremiumMarketing {
            return true
        }
        
        // Block the "Ad on App Open" home-screen banner (Pepsi, etc.)
        if path.contains("/ad-on-app-open") || path.contains("/ads/ad-on-app-open") {
            return true
        }
        
        // Block all other spclient /ads/* endpoints
        if path.contains("/ads/") {
            return true
        }
        
        // Block ad-logic (Marquee, in-stream ads)
        if path.contains("/ad-logic/") {
            return true
        }
        
        // Block DAC (Display Ad Container) — delivers search-page and home-page display ads
        // (Cartier on Search, Ross on Home as shown in the screenshots)
        if path.contains("/dac/view/v1/") {
            return true
        }
        
        // Block Esperanto ad slot service (in-stream and overlay ads)
        if path.contains("/esperanto/") && (path.contains("ad") || path.contains("slot")) {
            return true
        }
        
        // Block other known ad paths
        if path.contains("/ad-slot/") ||
           path.contains("/ad-inventory/") ||
           path.contains("/ad-on-app-open") ||
           path.contains("/sponsored/") ||
           path.contains("/promoted/") ||
           path.contains("/upsell/") ||
           path.contains("/premium-upsell") ||
           path.contains("/upsell-banner") ||
           path.contains("/upsell-card") ||
           path.contains("/referrals/upsell") ||
           path.contains("/campaign/") ||
           path.contains("/billboard/") ||
           path.contains("/banner/") ||
           path.contains("/interstitial/") ||
           path.contains("/overlay/") ||
           path.contains("/popup/") ||
           path.contains("/pop-up/") ||
           path.contains("/search-ad/") ||
           path.contains("/home-ad/") ||
           path.contains("/marquee/") ||
           path.contains("/leavebehind") ||
           path.contains("/leave-behind") ||
           path.contains("/display-ad/") ||
           path.contains("/fullbleed/") ||
           path.contains("/leaderboard/") ||
           path.contains("/ad-card/") ||
           path.contains("/sponsored-content/") ||
           path.contains("/sponsored-ad/") ||
           path.contains("/native-ad/") ||
           path.contains("/sponsored-shelf/") ||
           path.contains("/sponsored-row/") ||
           path.contains("/ad-shelf/") ||
           path.contains("/ad-row/") ||
           path.contains("/sponsored-item/") ||
           path.contains("/ad-item/") ||
           path.contains("/merchandising/") ||
           path.contains("/upgrade-component/") ||
           path.contains("/marketing/") ||
           path.contains("/home-ads/") ||
           path.contains("/search-ads/") {
            return true
        }
        
        // Block known ad hostnames
        if host.contains("doubleclick") ||
           host.contains("googlesyndication") ||
           host == "ad.spotify.com" ||
           host == "ads.spotify.com" ||
           host == "aet.spotify.com" ||
           host.hasPrefix("aet.") {
            return true
        }
        
        return false
    }

    /// Dedicated, non-essential measurement endpoints.
    ///
    /// Keep this list deliberately narrow. Spotify's first-party Event Sender
    /// also carries playback/royalty reports (RawCoreStream, msPlayed and
    /// offline reports), so its authenticated endpoint is intentionally not
    /// classified here. Blocking that endpoint would risk playback history,
    /// offline sync and repeated retry loops.
    var isSpotifyAnalyticsRelated: Bool {
        let path = self.path.lowercased()
        let host = (self.host ?? "").lowercased()

        // Firebase Analytics / Crashlytics / Firebase performance plumbing.
        // These hosts are not used for Spotify authentication or content.
        if host == "firebaselogging.googleapis.com" ||
           host == "crashlyticsreports-pa.googleapis.com" {
            return true
        }

        if host == "firebase-settings.crashlytics.com" ||
           host == "firebaseinstallations.googleapis.com" {
            return true
        }

        // Branch's safetrack hosts are specifically listed by Spotify as
        // tracking domains. Keep api3.branch.io available for deep-link
        // resolution; it is not a dedicated analytics endpoint.
        if host == "api-safetrack.branch.io" ||
           host == "api-safetrack-eu.branch.io" {
            return true
        }

        // ComScore measurement endpoints.
        if host == "census-app.scorecardresearch.com" ||
           host == "census-app-x.scorecardresearch.com" ||
           host == "b.scorecardresearch.com" ||
           host == "sb.scorecardresearch.com" ||
           host == "udm.scorecardresearch.com" {
            return true
        }

        // Google ad attribution and Cast/Google logging. Do not block OAuth
        // endpoints on googleapis.com; only these exact logging destinations.
        if host == "www.googleadservices.com" &&
           path.hasPrefix("/pagead/conversion") {
            return true
        }

        if host == "play.googleapis.com" && path == "/log" {
            return true
        }

        // Anonymous/public Spotify event batches are UI/marketing telemetry.
        // The authenticated Event Sender route is deliberately left intact
        // because it also contains core stream reporting.
        if host == "spclient.wg.spotify.com" &&
           path.hasPrefix("/gabo-receiver-service/public/v3/events") {
            return true
        }

        return false
    }

    /// A user-visible logout route. It is intentionally kept separate from
    /// automatic session invalidation: a manual logout must continue to work.
    var isExplicitLogoutEndpoint: Bool {
        let path = self.path.lowercased()
        return path == "/logout" ||
            path.hasSuffix("/logout") ||
            path.contains("/sign-out")
    }

    /// Endpoints which invalidate stored credentials without being the normal
    /// user-facing logout route. Keep this list narrow: product-state,
    /// license, melody and auth-expiry checks are state/refresh traffic, not
    /// proof that Spotify is logging the account out.
    var isSessionInvalidation: Bool {
        let path = self.path.lowercased()
        return isDeleteToken ||
            path.contains("/session/purge") ||
            path.contains("/token/revoke")
    }

    /// State checks worth recording while diagnosing a logout, but never
    /// replace or cancel. Returning their real response is important for
    /// token refresh and the session state machine.
    var isSessionStateCheck: Bool {
        let path = self.path.lowercased()
        return path.contains("auth/expire") ||
            (path.contains("melody") && path.contains("check")) ||
            path.contains("product-state") ||
            (path.contains("license") && path.contains("check"))
    }

    /// Used only for redacted diagnostics. Query parameters and bodies are
    /// deliberately excluded from the log.
    var isSessionDiagnosticRelated: Bool {
        isSessionInvalidation ||
            isExplicitLogoutEndpoint ||
            isSessionStateCheck ||
            isBootstrap ||
            isCustomize
    }
}
