import Orion
import UIKit

class UIOpenURLContextHook: ClassHook<UIOpenURLContext> {
    func URL() -> URL {
        let url = orig.URL()

        if url.isOpenSpotifySafariExtension {
            guard let fixed = Foundation.URL(string: "https:/\(url.path)") else { return url }
            return fixed
        }

        return url
    }
}
