import Orion
import UIKit
import SwiftUI

struct DarkPopUps: HookGroup { }

private var popUpContainerViewController: String {
    // For 9.1.x, use dummy UIView to avoid crashes
    if EeveeSpotify.hookTarget == .v91 {
        return "UIView"
    }
    
    switch EeveeSpotify.hookTarget {
    case .lastAvailableiOS14: return "SPTEncorePopUpContainer"
    default: return "SPTEncorePopUpContainer" // Use older class for compatibility
    }
}

class EncoreLabelHook: ClassHook<UIView> {
    typealias Group = DarkPopUps
    
    static var targetName: String {
        return EeveeSpotify.hookTarget == .v91 ? "UIView" : "SPTEncoreLabel"
    }

    func intrinsicContentSize() -> CGSize {
        if let viewController = WindowHelper.shared.viewController(for: target),
            NSStringFromClass(type(of: viewController)) == popUpContainerViewController
        {
            guard let firstSubview = target.subviews.first else {
                return orig.intrinsicContentSize()
            }
            let label = Dynamic.convert(firstSubview, to: UILabel.self)

            if !label.hasParent(matching: "Primary") {
                label.textColor = .white
            }
        }

        return orig.intrinsicContentSize()
    }
}

class SPTEncorePopUpContainerHook: ClassHook<UIViewController> {
    typealias Group = DarkPopUps
    static var targetName: String {
        return popUpContainerViewController
    }
    
    func containedView() -> SPTEncorePopUpDialog {
        return orig.containedView()
    }
    
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        containedView().uiView().backgroundColor = UIColor(Color(hex: "#242424"))
    }
}
