import Orion
import Foundation

// MARK: - Session Logout Protection
// Keep Spotify's normal auth/session state machine intact. The protection layer
// only blocks the narrow credential-deletion request after startup; all auth,
// refresh, reconnect and WebSocket lifecycle callbacks are forwarded.
// Each group is runtime-gated so renamed selectors don't crash on minor builds.

struct SessionLogoutAuthHookGroup: HookGroup { }
struct SessionLogoutConnectivityHookGroup: HookGroup { }
struct SessionLogoutAblyHookGroup: HookGroup { }

// Ably action name mapping for readable logs
private let ablyActionNames: [Int: String] = [
    0: "heartbeat", 1: "ack", 2: "nack", 3: "connect", 4: "connected",
    5: "disconnect", 6: "disconnected", 7: "close", 8: "closed", 9: "error",
    10: "attach", 11: "attached", 12: "detach", 13: "detached",
    14: "presence", 15: "message", 16: "sync", 17: "auth"
]

// MARK: - SPTAuthSessionImplementation — Core Session Hooks

class SPTAuthSessionHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAuthHookGroup
    static let targetName = "SPTAuthSessionImplementation"

    func logout() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] logout() forwarded at \(elapsed)s")
        orig.logout()
    }

    func logoutWithReason(_ reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] logoutWithReason forwarded at \(elapsed)s: \(String(describing: reason).prefix(160))")
        orig.logoutWithReason(reason)
    }

    func callSessionDidLogoutOnDelegateWithReason(_ reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] sessionDidLogout delegate forwarded at \(elapsed)s: \(String(describing: reason).prefix(160))")
        orig.callSessionDidLogoutOnDelegateWithReason(reason)
    }

    func logWillLogoutEventWithLogoutReason(_ reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] willLogout event at \(elapsed)s: \(String(describing: reason).prefix(160))")
        orig.logWillLogoutEventWithLogoutReason(reason)
    }

    func destroy() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        let trace = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
        writeDebugLog("[AUTH] session destroy forwarded at \(elapsed)s\n[TRACE] \(trace)")
        orig.destroy()
    }

    func productStateUpdated(_ state: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] productStateUpdated at \(elapsed)s -- \(state)")
        orig.productStateUpdated(state)
    }

    func tryReconnect(_ arg1: AnyObject, toAP arg2: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[AUTH] tryReconnect at \(elapsed)s -- AP: \(arg2)")
        orig.tryReconnect(arg1, toAP: arg2)
    }
}

// MARK: - SessionServiceImpl (Connectivity_SessionImpl module)

class SessionServiceImplHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutConnectivityHookGroup
    static let targetName = "_TtC24Connectivity_SessionImpl18SessionServiceImpl"

    func automatedLogoutThenLogin() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[SESSION] automatedLogoutThenLogin forwarded at \(elapsed)s")
        orig.automatedLogoutThenLogin()
    }

    func userInitiatedLogout() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        let queue = Thread.isMainThread ? "main" : "background"
        writeDebugLog("[SESSION] userInitiatedLogout forwarded at \(elapsed)s (\(queue))")
        orig.userInitiatedLogout()
    }

    func sessionDidLogout(_ session: AnyObject, withReason reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[SESSION] sessionDidLogout forwarded at \(elapsed)s: \(String(describing: reason).prefix(160))")
        orig.sessionDidLogout(session, withReason: reason)
    }
}

// MARK: - SPTAuthLegacyLoginControllerImplementation

class LegacyLoginControllerHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAuthHookGroup
    static let targetName = "SPTAuthLegacyLoginControllerImplementation"

    func sessionDidLogout(_ session: AnyObject, withReason reason: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[LEGACY] sessionDidLogout forwarded at \(elapsed)s: \(String(describing: reason).prefix(160))")
        orig.sessionDidLogout(session, withReason: reason)
    }

    func destroySession() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[LEGACY] destroySession forwarded at \(elapsed)s")
        orig.destroySession()
    }

    func forgetStoredCredentials() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[LEGACY] forgetStoredCredentials forwarded at \(elapsed)s")
        orig.forgetStoredCredentials()
    }

    func invalidate() {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[LEGACY] invalidate forwarded at \(elapsed)s")
        orig.invalidate()
    }
}

// NOTE: ColdStartupTimeKeeperImplementation is a pure Swift class (not NSObject).
// Cannot hook it with Orion — crashes with targetHasIncompatibleType.
// NOTE: executeBlockRunner on SPTAsyncNativeTimerManagerThreadImpl is too broad —
// blocking it kills ALL timers including playback advancement.

// MARK: - Ably WebSocket Transport Hooks
// Observe session-related protocol traffic without swallowing lifecycle
// events. Dropping disconnect/error/auth frames leaves Ably and Spotify's
// session state machines out of sync and can itself produce a logout loop.

private func extractAblyAction(_ text: String) -> Int? {
    guard let range = text.range(of: "\"action\":") else { return nil }
    let afterAction = text[range.upperBound...]
    let digits = afterAction.prefix(while: { $0.isNumber })
    return Int(digits)
}

class ARTWebSocketTransportHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAblyHookGroup
    static let targetName = "ARTWebSocketTransport"

    func webSocket(_ ws: AnyObject, didReceiveMessage message: AnyObject) {
        if let msgString = message as? String {
            if let action = extractAblyAction(msgString) {
                let actionName = ablyActionNames[action] ?? "unknown"
                let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
                writeDebugLog("[ABLY] Received action \(action) (\(actionName)) at \(elapsed)s; forwarding")
            }
        }
        orig.webSocket(ws, didReceiveMessage: message)
    }

    func webSocket(_ ws: AnyObject, didFailWithError error: AnyObject) {
        let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
        writeDebugLog("[ABLY] WebSocket didFailWithError forwarded at \(elapsed)s: \(String(describing: error).prefix(160))")
        orig.webSocket(ws, didFailWithError: error)
    }
}

// MARK: - Ably SRWebSocket Frame Hook

class ARTSRWebSocketHook: ClassHook<NSObject> {
    typealias Group = SessionLogoutAblyHookGroup
    static let targetName = "ARTSRWebSocket"

    func _handleFrameWithData(_ data: NSData, opCode code: Int) {
        if code == 1,
           let text = String(data: data as Data, encoding: .utf8) {
            if let action = extractAblyAction(text) {
                let actionName = ablyActionNames[action] ?? "unknown"
                let elapsed = Int(Date().timeIntervalSince(tweakInitTime))
                writeDebugLog("[ABLY-SR] Received action \(action) (\(actionName)) at \(elapsed)s; forwarding")
            }
        }
        orig._handleFrameWithData(data, opCode: code)
    }
}
