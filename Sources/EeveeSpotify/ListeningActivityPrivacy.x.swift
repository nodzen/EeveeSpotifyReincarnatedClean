import Foundation
import Orion

// Listening Activity is a normal Spotify setting, so the tweak must not
// globally disable the feature or replace Spotify's publisher. Instead, keep
// the native setting value authoritative: once a user stores OFF, reads stay
// OFF and later writes attempting to turn it back ON are ignored.
struct ListeningActivityPrivacyGroup: HookGroup { }

private func listeningActivityKey(_ key: NSString) -> String {
    key as String
}

/// Foundation's UserDefaults is the native persistence layer used by
/// Session.UserDefaultsLocalSettings. Hooking this layer keeps Spotify's own
/// SettingsImpl/ProviderImpl state machine intact and makes its publisher see
/// the same OFF value that the UI sees.
class ListeningActivityUserDefaultsHook: ClassHook<NSObject> {
    typealias Group = ListeningActivityPrivacyGroup
    static let targetName = "NSUserDefaults"

    private func isLatchedOff() -> Bool {
        guard let defaults = target as? UserDefaults else { return false }
        return defaults.bool(forKey: ListeningActivityPrivacyPolicy.latchKey)
    }

    private func storedActivityValue(for key: NSString) -> Any? {
        orig.objectForKey(key)
    }

    private func forceOffIfNeeded(_ key: NSString, storedValue: Any?) -> Any? {
        guard ListeningActivityPrivacyPolicy.isListeningActivityKey(listeningActivityKey(key)) else {
            return storedValue
        }

        let latchedOff = isLatchedOff()
        if !latchedOff, ListeningActivityPrivacyPolicy.boolValue(storedValue) == false {
            // Persist the latch in the native suite. This is deliberately not
            // UserDefaults.standard: account-scoped Spotify settings must not
            // affect another logged-in account.
            orig.setBool(true, forKey: ListeningActivityPrivacyPolicy.latchKey as NSString)
        }

        guard ListeningActivityPrivacyPolicy.shouldForceOff(
            latchedOff: latchedOff,
            storedValue: storedValue
        ) else {
            return storedValue
        }
        return NSNumber(value: false)
    }

    @objc(objectForKey:)
    func objectForKey(_ key: NSString) -> Any? {
        forceOffIfNeeded(key, storedValue: storedActivityValue(for: key))
    }

    @objc(boolForKey:)
    func boolForKey(_ key: NSString) -> Bool {
        guard ListeningActivityPrivacyPolicy.isListeningActivityKey(listeningActivityKey(key)) else {
            return orig.boolForKey(key)
        }

        let storedValue = storedActivityValue(for: key)
        let value = forceOffIfNeeded(key, storedValue: storedValue)
        return ListeningActivityPrivacyPolicy.boolValue(value) ?? orig.boolForKey(key)
    }

    @objc(setObject:forKey:)
    func setObject(_ value: Any?, forKey key: NSString) {
        let lowered = (key as String).lowercased()
        if lowered.contains("activity") {
            writeDebugLog("[LISTENING-HOOK] setObject key=\(key) value=\(String(describing: value))")
        }
        guard ListeningActivityPrivacyPolicy.isListeningActivityKey(listeningActivityKey(key)) else {
            orig.setObject(value, forKey: key)
            return
        }

        let storedValue = storedActivityValue(for: key)
        let latchedOff = isLatchedOff()
        guard !ListeningActivityPrivacyPolicy.shouldRejectWrite(
            latchedOff: latchedOff,
            storedValue: storedValue,
            requestedValue: value
        ) else {
            writeDebugLog("[LISTENING] Ignored native attempt to re-enable Listening Activity")
            return
        }

        if ListeningActivityPrivacyPolicy.boolValue(value) == false {
            orig.setBool(true, forKey: ListeningActivityPrivacyPolicy.latchKey as NSString)
            writeDebugLog("[LISTENING] Persisted native Listening Activity=OFF")
        }
        orig.setObject(value, forKey: key)
    }

    @objc(setBool:forKey:)
    func setBool(_ value: Bool, forKey key: NSString) {
        guard ListeningActivityPrivacyPolicy.isListeningActivityKey(listeningActivityKey(key)) else {
            orig.setBool(value, forKey: key)
            return
        }
        setObject(NSNumber(value: value), forKey: key)
    }

    @objc(removeObjectForKey:)
    func removeObjectForKey(_ key: NSString) {
        let lowered = (key as String).lowercased()
        if lowered.contains("activity") {
            writeDebugLog("[LISTENING-HOOK] removeObject key=\(key)")
        }
        guard ListeningActivityPrivacyPolicy.isListeningActivityKey(listeningActivityKey(key)) else {
            orig.removeObjectForKey(key)
            return
        }

        let storedValue = storedActivityValue(for: key)
        guard !ListeningActivityPrivacyPolicy.shouldRejectWrite(
            latchedOff: isLatchedOff(),
            storedValue: storedValue,
            requestedValue: nil
        ) else {
            writeDebugLog("[LISTENING] Preserved native Listening Activity=OFF")
            return
        }
        orig.removeObjectForKey(key)
    }
}

func activateListeningActivityPrivacy() {
    let className = ListeningActivityUserDefaultsHook.targetName
    guard let cls = NSClassFromString(className) else {
        writeDebugLog("[LISTENING] Skipped native setting hook (NSUserDefaults unavailable)")
        return
    }

    let selectors = [
        "objectForKey:",
        "boolForKey:",
        "setObject:forKey:",
        "setBool:forKey:",
        "removeObjectForKey:",
    ].map(NSSelectorFromString)

    guard selectors.allSatisfy({ class_getInstanceMethod(cls, $0) != nil }) else {
        writeDebugLog("[LISTENING] Skipped native setting hook (NSUserDefaults API mismatch)")
        return
    }

    ListeningActivityPrivacyGroup().activate()
    writeDebugLog("[LISTENING] Activated account-scoped native setting guard")
}
