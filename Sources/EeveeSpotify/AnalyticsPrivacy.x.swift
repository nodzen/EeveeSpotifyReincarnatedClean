import Foundation

// MARK: - Known analytics SDK collection switches
//
// Spotify embeds these SDKs directly, so importing their private/static
// headers would make the tweak version-fragile. Resolve only the documented
// Objective-C selectors at runtime. A missing class or selector is a no-op;
// the URLSession guard remains the fallback that prevents uploads.

private func disableClassBooleanSetter(_ className: String, selectorName: String) -> Bool {
    guard let cls = NSClassFromString(className) as? NSObject.Type else {
        return false
    }

    let selector = Selector((selectorName))
    guard cls.responds(to: selector) else {
        return false
    }

    cls.perform(selector, with: NSNumber(value: false))
    return true
}

private func disableInstanceBooleanSetter(
    _ className: String,
    sharedSelectorName: String,
    setterName: String
) -> Bool {
    guard let cls = NSClassFromString(className) as? NSObject.Type else {
        return false
    }

    let sharedSelector = Selector((sharedSelectorName))
    let setter = Selector((setterName))
    guard cls.responds(to: sharedSelector),
          let instance = cls.perform(sharedSelector)?.takeUnretainedValue() as? NSObject,
          instance.responds(to: setter) else {
        return false
    }

    instance.perform(setter, with: NSNumber(value: false))
    return true
}

/// Disable collection in SDKs when the current Spotify build exposes the
/// standard switches. This is deliberately best-effort and never replaces
/// the network classifier, because SDK initialization order can vary by build.
func disableKnownSpotifyAnalyticsCollection() {
    guard UserDefaults.blockSpotifyAnalytics else {
        return
    }

    var disabled: [String] = []

    if disableClassBooleanSetter(
        "FIRAnalytics",
        selectorName: "setAnalyticsCollectionEnabled:"
    ) {
        disabled.append("Firebase Analytics")
    }

    if disableInstanceBooleanSetter(
        "FIRCrashlytics",
        sharedSelectorName: "crashlytics",
        setterName: "setCrashlyticsCollectionEnabled:"
    ) {
        disabled.append("Crashlytics")
    }

    if disableInstanceBooleanSetter(
        "FIRPerformance",
        sharedSelectorName: "sharedInstance",
        setterName: "setDataCollectionEnabled:"
    ) {
        disabled.append("Firebase Performance")
    }

    if disabled.isEmpty {
        writeDebugLog("[PRIVACY] SDK collection switches unavailable; network block remains active")
    } else {
        writeDebugLog("[PRIVACY] Disabled SDK collection: " + disabled.joined(separator: ", "))
    }
}
