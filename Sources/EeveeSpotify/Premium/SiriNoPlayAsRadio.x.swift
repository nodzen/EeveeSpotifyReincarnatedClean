import Orion
import Intents

class INMediaItemHook: ClassHook<INMediaItem> {
    typealias Group = PremiumUIHooksGroup
    
    func identifier() -> String {
        var identifier = orig.identifier()
        
        if identifier.contains("play-command") {
            let components = identifier.components(separatedBy: ":")
            guard components.count > 2,
                  let jsonData = Data(base64Encoded: components[2]),
                  var json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let feedbackDetails = json["feedback_details"] as? [String: Any],
                  feedbackDetails["restriction"] as? String == "play-as-radio",
                  var context = json["context"] as? [String: Any],
                  let urlString = context["url"] as? String else {
                return identifier
            }

            context["url"] = urlString.removeMatches(":station")
            json["context"] = context

            if let newData = try? JSONSerialization.data(withJSONObject: json) {
                identifier = "spotify:play-command:\(newData.base64EncodedString())"
            }
        }
        
        return identifier
    }
}
