// Spotify 9.1.x has several promotional paths which do not go through the
// legacy Encore upsell services. Keep these hooks narrow and optional:
// service entry points are killed only for modules whose names identify them
// as ads/promotions, while the shared banner presenter filters only an ad or
// Premium banner by its actual localized content.

import Foundation
import ObjectiveC.runtime
import Orion
import UIKit

struct AdOnAppOpenServiceGroup: HookGroup {}
struct AdOnAppOpenViewGroup: HookGroup {}
struct AdOnAppOpenFooterViewGroup: HookGroup {}
struct AdsBaseSwiftServiceGroup: HookGroup {}
struct EmbeddedPlaylistAdServiceGroup: HookGroup {}
struct MarqueeServiceGroup: HookGroup {}
struct PremiumUpsellHeaderViewGroup: HookGroup {}
struct PremiumUpsellBannerElementGroup: HookGroup {}
struct PremiumUpsellViewControllerGroup: HookGroup {}
struct UpsellSheetViewControllerGroup: HookGroup {}
struct SpotifyBannerPresentationGroup: HookGroup {}

private let logModernPromotionBlockers = EeveeDebug.enabled

@inline(__always)
private func promotionLog(_ message: String) {
    if logModernPromotionBlockers {
        NSLog("[EeveeSpotify][PromotionBlock] %@", message)
    }
}

// App-open advertisements have their own service and are independent from
// the regular in-stream ad service. This target exists in both 9.1.76 and
// 9.1.80 and exposes the stable SPTService load entry point.
class AdOnAppOpenServiceKill: ClassHook<NSObject> {
    typealias Group = AdOnAppOpenServiceGroup
    static let targetName =
        "_TtC29AdsStandalone_AdOnAppOpenImpl22AdOnAppOpenServiceImpl"

    func load() {
        promotionLog("suppressed AdOnAppOpenServiceImpl.load")
        return
    }
}

class AdOnAppOpenViewKill: ClassHook<UIViewController> {
    typealias Group = AdOnAppOpenViewGroup
    static let targetName =
        "_TtC29AdsStandalone_AdOnAppOpenImpl25AdOnAppOpenViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        promotionLog("dismissed AdOnAppOpenViewController")
        target.dismiss(animated: false)
    }
}

class AdOnAppOpenFooterViewKill: ClassHook<UIView> {
    typealias Group = AdOnAppOpenFooterViewGroup
    static let targetName =
        "_TtC29AdsStandalone_AdOnAppOpenImpl21AdOnAppOpenFooterView"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            promotionLog("removed AdOnAppOpenFooterView")
            target.removeFromSuperview()
        }
    }
}

// This is the common Swift ads infrastructure used by several newer ad
// surfaces. It is deliberately separate from SPTAdsProductState so the
// premium/product-state code remains untouched.
class AdsBaseSwiftServiceKill: ClassHook<NSObject> {
    typealias Group = AdsBaseSwiftServiceGroup
    static let targetName =
        "_TtC28AdsPlatform_AdsBaseSwiftImpl23AdsBaseSwiftServiceImpl"

    func load() {
        promotionLog("suppressed AdsBaseSwiftServiceImpl.load")
        return
    }
}

// Embedded playlist cards are another ad-backed renderer. The service is
// present in 9.1.76 and 9.1.80 and is separate from the NPV service already
// covered by EeveeAdBlockerExtended.
class EmbeddedPlaylistAdServiceKill: ClassHook<NSObject> {
    typealias Group = EmbeddedPlaylistAdServiceGroup
    static let targetName =
        "_TtC32AdsEmbedded_EmbeddedPlaylistImpl27EmbeddedPlaylistServiceImpl"

    func load() {
        promotionLog("suppressed EmbeddedPlaylistServiceImpl.load")
        return
    }
}

// Marquee is Spotify's full-screen artist/brand promotion surface. Remote
// configuration normally disables it, but killing its service also covers a
// cached or late-refetched ad response.
class MarqueeServiceKill: ClassHook<NSObject> {
    typealias Group = MarqueeServiceGroup
    static let targetName = "_TtC19Marquee_MarqueeImpl14MarqueeService"

    func load() {
        promotionLog("suppressed MarqueeService.load")
        return
    }
}

// The Premium destination page can materialize its own header after the
// generic HUB response has already been processed. This view is a precise
// Premium-only fallback and is not used by regular Spotify banners.
class PremiumUpsellHeaderViewKill: ClassHook<UIView> {
    typealias Group = PremiumUpsellHeaderViewGroup
    static let targetName =
        "_TtC20PremiumUpsell_ECMKit30PremiumUpsellHeaderCentralView"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            promotionLog("removed PremiumUpsellHeaderCentralView")
            target.removeFromSuperview()
        }
    }
}

// Added to the 9.1.80 queue integration. The class is Swift-only in the
// binary, so the hook is optional and activates only when Objective-C runtime
// metadata exposes the inherited UIView callback.
class PremiumUpsellBannerElementKill: ClassHook<UIView> {
    typealias Group = PremiumUpsellBannerElementGroup
    static let targetName =
        "_TtC24Jam_QueueIntegrationImpl28PremiumUpsellBannerElementUI"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            promotionLog("removed PremiumUpsellBannerElementUI")
            target.removeFromSuperview()
        }
    }
}

// These controllers are dedicated Premium upsell pages/sheets. Dismissing
// after appearance leaves ordinary Spotify navigation intact while preventing
// a route which was created before the service/configuration blocker ran from
// remaining on screen.
class PremiumUpsellViewControllerKill: ClassHook<UIViewController> {
    typealias Group = PremiumUpsellViewControllerGroup
    static let targetName =
        "_TtC31PremiumUpsell_UpsellServiceImpl20UpsellViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        promotionLog("dismissed Premium UpsellViewController")
        target.dismiss(animated: false)
    }
}

class UpsellSheetViewControllerKill: ClassHook<UIViewController> {
    typealias Group = UpsellSheetViewControllerGroup
    static let targetName =
        "_TtC21Upsells_SheetPageImpl32UpsellSheetLoadingViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        promotionLog("dismissed UpsellSheetLoadingViewController")
        target.dismiss(animated: false)
    }
}

private enum SpotifyBannerClassifier {
    private static let premiumKeywords = [
        "premium", "upgrade", "subscribe", "subscription", "upsell",
        "paywall", "free tier", "free account", "ad-free", "ad free",
        "try premium", "get premium", "go premium", "без рекламы",
        "премиум", "подписк", "без ограничений", "бесплатный аккаунт",
    ]

    private static let adKeywords = [
        "advertisement", "sponsored", "promoted", "display ad", "display-ad",
        "native ad", "native-ad", "ad on app open", "ad-on-app-open",
        "leavebehind", "leave-behind", "brand partner", "реклама", "спонсор",
    ]

    private static func object(_ object: NSObject, key: String) -> NSObject? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.value(forKey: key) as? NSObject
    }

    private static func string(_ object: NSObject, key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.value(forKey: key) as? String
    }

    private static func text(from object: NSObject) -> [String] {
        // These are the public ObjC-facing properties of SPTBannerItem. Do
        // not inspect arbitrary KVC keys: value(forKey:) can raise for private
        // Swift storage and a banner must never be able to crash Spotify.
        [
            "localizedTitle", "localizedMessage", "localizedActionButtonTitle",
            "title", "subtitle", "message", "description",
        ].compactMap { string(object, key: $0) }
    }

    static func isPromotional(_ ticket: NSObject) -> Bool {
        let item = object(ticket, key: "bannerItem") ?? ticket
        let classNames = [
            NSStringFromClass(type(of: ticket)),
            NSStringFromClass(type(of: item)),
        ].joined(separator: " ").lowercased()

        // Do not match the generic substring "ad": unrelated Spotify classes
        // such as "Adaptive..." would otherwise be hidden as advertisements.
        if classNames.contains("upsell") || classNames.contains("premium") ||
            classNames.contains("sponsor") || classNames.contains("adonappopen") ||
            classNames.contains("embeddedad") {
            return true
        }

        for value in text(from: item) + text(from: ticket) {
            let lower = value.lowercased()
            if adKeywords.contains(where: { lower.contains($0) }) ||
                premiumKeywords.contains(where: { lower.contains($0) }) {
                return true
            }
        }

        return false
    }
}

// SPTBanner is shared by informational notices and promotional messages. A
// content-aware hook preserves the former and drops only the latter before
// SPTBannerViewController can place it at the top of the screen.
class SpotifyBannerPresentationKill: ClassHook<NSObject> {
    typealias Group = SpotifyBannerPresentationGroup
    static let targetName = "SPTBannerPresentationManagerImplementation"

    func presentBannerWithTicket(_ ticket: NSObject) {
        if SpotifyBannerClassifier.isPromotional(ticket) {
            promotionLog("blocked promotional SPTBanner")
            return
        }
        orig.presentBannerWithTicket(ticket)
    }
}

private var modernPromotionActivationAttempt = 0
private let modernPromotionMaxActivationAttempts = 30

private func activateIfAvailable(
    className: String,
    selectorName: String,
    activate: () -> Void
) -> Bool {
    guard let cls = NSClassFromString(className),
          class_getInstanceMethod(cls, NSSelectorFromString(selectorName)) != nil else {
        return false
    }
    activate()
    return true
}

func activateModernPromotionBlockers() {
    let serviceTargets: [(String, String, () -> Void)] = [
        (
            AdOnAppOpenServiceKill.targetName,
            "AdOnAppOpenServiceImpl",
            { if !AdOnAppOpenServiceGroup.isActive { AdOnAppOpenServiceGroup().activate() } }
        ),
        (
            AdsBaseSwiftServiceKill.targetName,
            "AdsBaseSwiftServiceImpl",
            { if !AdsBaseSwiftServiceGroup.isActive { AdsBaseSwiftServiceGroup().activate() } }
        ),
        (
            EmbeddedPlaylistAdServiceKill.targetName,
            "EmbeddedPlaylistServiceImpl",
            { if !EmbeddedPlaylistAdServiceGroup.isActive { EmbeddedPlaylistAdServiceGroup().activate() } }
        ),
        (
            MarqueeServiceKill.targetName,
            "MarqueeService",
            { if !MarqueeServiceGroup.isActive { MarqueeServiceGroup().activate() } }
        ),
    ]

    for (className, label, activate) in serviceTargets {
        if activateIfAvailable(className: className, selectorName: "load", activate: activate) {
            NSLog("[EeveeSpotify][PromotionBlock] %@ activated", label)
        }
    }

    let viewTargets: [(String, String, () -> Void)] = [
        (
            AdOnAppOpenViewKill.targetName,
            "AdOnAppOpenViewController",
            { if !AdOnAppOpenViewGroup.isActive { AdOnAppOpenViewGroup().activate() } }
        ),
        (
            AdOnAppOpenFooterViewKill.targetName,
            "AdOnAppOpenFooterView",
            { if !AdOnAppOpenFooterViewGroup.isActive { AdOnAppOpenFooterViewGroup().activate() } }
        ),
        (
            PremiumUpsellHeaderViewKill.targetName,
            "PremiumUpsellHeaderCentralView",
            { if !PremiumUpsellHeaderViewGroup.isActive { PremiumUpsellHeaderViewGroup().activate() } }
        ),
        (
            PremiumUpsellBannerElementKill.targetName,
            "PremiumUpsellBannerElementUI",
            { if !PremiumUpsellBannerElementGroup.isActive { PremiumUpsellBannerElementGroup().activate() } }
        ),
        (
            PremiumUpsellViewControllerKill.targetName,
            "PremiumUpsellViewController",
            { if !PremiumUpsellViewControllerGroup.isActive { PremiumUpsellViewControllerGroup().activate() } }
        ),
        (
            UpsellSheetViewControllerKill.targetName,
            "UpsellSheetLoadingViewController",
            { if !UpsellSheetViewControllerGroup.isActive { UpsellSheetViewControllerGroup().activate() } }
        ),
    ]

    for (className, label, activate) in viewTargets {
        if activateIfAvailable(
            className: className,
            selectorName: "viewDidAppear:",
            activate: activate
        ) || activateIfAvailable(
            className: className,
            selectorName: "didMoveToSuperview",
            activate: activate
        ) {
            NSLog("[EeveeSpotify][PromotionBlock] %@ activated", label)
        }
    }

    if activateIfAvailable(
        className: SpotifyBannerPresentationKill.targetName,
        selectorName: "presentBannerWithTicket:",
        activate: {
            if !SpotifyBannerPresentationGroup.isActive {
                SpotifyBannerPresentationGroup().activate()
            }
        }
    ) {
        NSLog("[EeveeSpotify][PromotionBlock] SPTBanner presentation filter activated")
    }

    // Spotify loads some feature modules lazily. Retry only while at least one
    // known target is still absent; HookGroup.isActive prevents duplicate
    // swizzles after a later retry.
    let allKnownGroupsActive =
        AdOnAppOpenServiceGroup.isActive &&
        AdsBaseSwiftServiceGroup.isActive &&
        EmbeddedPlaylistAdServiceGroup.isActive &&
        MarqueeServiceGroup.isActive &&
        SpotifyBannerPresentationGroup.isActive

    if !allKnownGroupsActive && modernPromotionActivationAttempt < modernPromotionMaxActivationAttempts {
        modernPromotionActivationAttempt += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            activateModernPromotionBlockers()
        }
    }
}
