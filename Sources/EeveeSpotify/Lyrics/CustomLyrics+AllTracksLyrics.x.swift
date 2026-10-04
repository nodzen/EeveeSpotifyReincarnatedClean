import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

// Spotify decides whether to create the /color-lyrics request from this
// metadata flag. Keep the 9.1.x hook isolated from the older error-handling
// group: that group also contains private APIs which no longer exist on 9.1.x.
class SPTPlayerTrackV91LyricsAvailabilityHook: ClassHook<NSObject> {
    typealias Group = V91LyricsAvailabilityGroup
    static let targetName = "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
}

// Legacy combined metadata/URI behavior. Do not activate its entire group on
// 9.1.x; the isolated metadata-only hook above is the compatible subset.
class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
    
    func URI() -> NSURL? {
        let uri = orig.URI()

        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {
            return uri
        }

        return NSURL(string: "spotify:track:")!
    }
}

// LyricsScrollProvider not compatible with 9.1.x
class LyricsScrollProviderHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = "Lyrics_CoreImpl.LyricsScrollProvider"
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return true
    }
}

// NPVScrollViewController not compatible with 9.1.x  
class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x (moved from ModernLyricsGroup)
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

// V91-compatible version of NPVScrollViewController hook
class NPVScrollViewControllerV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewDidLoad() {
        orig.viewDidLoad()

        npvScrollViewController = Dynamic.convert(
            target,
            to: NPVScrollViewController.self
        )
        installLyricsUIRefreshHandlerIfNeeded()
        ScrollsitaLyricsCardPatcher.retryLyricsUIRefreshIfNeeded()
        writeDebugLog("[NPV] captured modern controller in viewDidLoad")
    }

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)

        npvScrollViewController = Dynamic.convert(
            target,
            to: NPVScrollViewController.self
        )
        installLyricsUIRefreshHandlerIfNeeded()
        ScrollsitaLyricsCardPatcher.retryLyricsUIRefreshIfNeeded()
        writeDebugLog("[NPV] captured modern controller in viewWillAppear")
    }

    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

private var lyricsUIRefreshHandlerInstalled = false

private func installLyricsUIRefreshHandlerIfNeeded() {
    guard !lyricsUIRefreshHandlerInstalled else { return }
    lyricsUIRefreshHandlerInstalled = true

    ScrollsitaLyricsCardPatcher.installLyricsUIRefreshHandler { trackID in
        guard let controller = npvScrollViewController as? UIViewController,
              controller.isViewLoaded,
              let view = controller.viewIfLoaded,
              view.window != nil else {
            writeDebugLog("[LyricsUI] refresh deferred: NPV controller is not visible track=\(trackID)")
            return false
        }

        // The 9.1.80 NPV controller no longer implements the old
        // collectionView() accessor. Walk its actual UIKit view tree instead
        // and use the largest collection view, which is the NPV page data
        // source rather than a nested card/carousel collection.
        let collectionViews = lyricsCollectionViews(in: view)
        guard let collectionView = collectionViews.max(by: { lhs, rhs in
            let lhsArea = lhs.bounds.width * lhs.bounds.height
            let rhsArea = rhs.bounds.width * rhs.bounds.height
            return lhsArea < rhsArea
        }), collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
            writeDebugLog("[LyricsUI] refresh deferred: NPV collection view not ready track=\(trackID)")
            return false
        }

        // Reload the existing data source, not the controller lifecycle. The
        // latter is exactly what the previous build did, and Spotify ignored
        // it because the diffable card remained configured with its old
        // /color-lyrics result. reloadData() is public UIKit API and does not
        // depend on Spotify's removed private selector.
        collectionView.reloadData()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        writeDebugLog("[LyricsUI] reloaded NPV collection view track=\(trackID) count=\(collectionViews.count) dataSource=\(String(describing: collectionView.dataSource.map { type(of: $0) }))")
        return true
    }
}

private func lyricsCollectionViews(in root: UIView) -> [UICollectionView] {
    var result: [UICollectionView] = []
    var pending: [UIView] = [root]

    while let view = pending.first {
        pending.removeFirst()
        if let collectionView = view as? UICollectionView {
            result.append(collectionView)
        }
        pending.append(contentsOf: view.subviews)
    }

    return result
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // Dummy target for 9.1.6
        : "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
