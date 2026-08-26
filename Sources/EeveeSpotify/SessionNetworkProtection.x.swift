import Foundation
import Orion

// Network-only session protection is separate from auth/WebSocket lifecycle
// hooks. It owns request cancellation and leaves Spotify's state machine intact.
struct SessionLogoutNetworkHookGroup: HookGroup { }

class URLSessionTaskResumeHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutNetworkHookGroup
    static let targetName = "NSURLSessionTask"

    func resume() {
        if let task = target as? URLSessionTask,
           let url = task.currentRequest?.url ?? task.originalRequest?.url,
           let host = url.host?.lowercased() {

            let elapsed = Date().timeIntervalSince(tweakInitTime)
            let elapsedInt = Int(elapsed)
            let path = url.path

            if AnalyticsNetworkPolicy.shouldCancel(url) {
                let method = task.currentRequest?.httpMethod ?? "?"
                writeDebugLog("[NET] Cancelling dedicated analytics: \(method) \(host)\(path)")
                orig.resume()
                task.cancel()
                return
            }

            let isAuthRelated = host.contains("login5") ||
                host.contains("apresolve") ||
                (host.contains("googleapis.com") && path.contains("/token")) ||
                path.contains("bootstrap/v1/bootstrap") ||
                path.lowercased().contains("deletetoken") ||
                path.contains("signup/public") ||
                path.contains("pses/screenconfig") ||
                path.contains("logout") ||
                path.contains("sign-out") ||
                path.contains("session/purge") ||
                path.contains("token/revoke") ||
                path.contains("auth/expire") ||
                path.contains("product-state") ||
                path.contains("melody") ||
                path.contains("auth/v1")

            if isAuthRelated {
                let method = task.currentRequest?.httpMethod ?? "?"
                writeDebugLog("[NET] Auth request: \(method) \(host)\(path) at \(elapsedInt)s")
            }

            let isSpotifyFirstParty = host == "spclient.wg.spotify.com" ||
                host.hasSuffix(".spotify.com")
            if isSpotifyFirstParty, elapsed > 30, url.isDeleteToken {
                writeDebugLog("[NET] Cancelling DeleteToken at \(elapsedInt)s")
                orig.resume()
                task.cancel()
                return
            }
        }
        orig.resume()
    }
}
