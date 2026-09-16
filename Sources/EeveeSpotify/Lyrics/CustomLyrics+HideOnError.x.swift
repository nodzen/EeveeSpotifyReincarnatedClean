import Orion
import UIKit

// ErrorViewController doesn't exist in Spotify 9.1.x - separate group to avoid crashes
class ErrorViewControllerHook: ClassHook<UIViewController> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.ErrorViewController"
        default: return "Lyrics_NPVCommunicatorImpl.ErrorViewController"
        }
    }
    
    func loadView() {
        orig.loadView()
        
        guard UserDefaults.lyricsOptions.hideOnError else {
            return
        }
        
        if let controller = nowPlayingScrollViewController {
            controller.dataSource.activeProviders.removeAll {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }
            
            controller.collectionView().reloadData()
        }
        else if let controller = npvScrollViewController, let dataSource = scrollDataSource {
            // Spotify 9.1.80's NPV controller no longer implements the old
            // collectionView selector. The legacy error hook is normally
            // inactive there, but keep this branch fail-closed in case a
            // group is activated by another build configuration.
            let controllerObject: AnyObject = controller
            let collectionViewSelector = NSSelectorFromString("collectionView")
            guard let controllerClass = object_getClass(controllerObject),
                  class_getInstanceMethod(controllerClass, collectionViewSelector) != nil else {
                writeDebugLog("[Lyrics] skip hide-on-error: NPV controller has no collectionView selector")
                return
            }

            guard let lyricsProviderIndex = dataSource.activeProviders.firstIndex(where: {
                NSStringFromClass(type(of: $0)) == HookTargetNameHelper.lyricsScrollProvider
            }) else {
                return
            }
            
            let collectionView = controller.collectionView()
            let dataSource = Ivars<__UIDiffableDataSource>(collectionView.dataSource!)._impl
            
            let itemIdentifiers = dataSource.itemIdentifiers()
            guard lyricsProviderIndex < itemIdentifiers.count else {
                return
            }
            let lyricsProviderItemIdentifier = itemIdentifiers[lyricsProviderIndex]
            
            dataSource.deleteItemsWithIdentifiers([lyricsProviderItemIdentifier])
        }
    }
}
