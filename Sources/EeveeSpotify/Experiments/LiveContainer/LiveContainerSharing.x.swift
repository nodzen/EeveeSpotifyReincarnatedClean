import Orion
import UIKit
import UniformTypeIdentifiers

class UIApplicationLiveContainerSharingHook: ClassHook<UIApplication> {
    func openURL(
        _ url: URL,
        options: [String: Any],
        completionHandler: (@MainActor (ObjCBool) -> Void)?
    ) {
        if UserDefaults.experimentsOptions.liveContainerSharing, !target.canOpenURL(url) {
            UIPasteboard.general.addItems([[UTType.url.identifier: url]])
            
            let base64 = url.dataRepresentation.base64EncodedString()
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let liveContainerUrl = URL(string: "livecontainer://open-url?url=\(base64)") else {
                return
            }
            
            orig.openURL(
                liveContainerUrl,
                options: options,
                completionHandler: { success in
                    completionHandler?(true)
                    
                    if !success.boolValue {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "could_not_share_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                }
            )
            
            return
        }
        
        orig.openURL(url, options: options, completionHandler: completionHandler)
    }
}
