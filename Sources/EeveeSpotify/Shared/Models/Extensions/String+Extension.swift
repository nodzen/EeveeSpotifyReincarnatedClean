import Foundation 
import UIKit
import NaturalLanguage

extension String {
    static func ~= (lhs: String, rhs: String) -> Bool {
        lhs.firstMatch(rhs) != nil
    }
    
    var localized: String {
        BundleHelper.shared.localizedString(self)
    }
    
    var uiKitLocalized: String {
        let bundle = Bundle(for: UIApplication.self)
        return bundle.localizedString(forKey: self, value: nil, table: nil)
    }
    
    func localizeWithFormat(_ arguments: CVarArg...) -> String {
        String(format: self.localized, arguments: arguments)
    }

    var range: NSRange { 
        NSRange(self.startIndex..., in: self) 
    }

    var strippedTrackTitle: String {
        String(
            self
            .removeMatches("\\(.*\\)")
            .removeMatches("- .*")
            .trimmingCharacters(in: .whitespaces)
        )
    }

    var lyricsNoteIfEmpty: String {
        self.isEmpty ? "♪" : self
    }

    func containsInsensitive<S: StringProtocol>(_ s: S) -> Bool {
        self.range(of: s, options: .caseInsensitive) != nil
    }

    func firstMatch(_ pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: self, range: self.range)
    }

    func removeMatches(_ pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        return regex.stringByReplacingMatches(
            in: self,
            range: self.range,
            withTemplate: ""
        )
    }
    
    var isCanBeRomanizedLanguage: Bool {
        ["ja", "ko", "z1"].contains(self) || self.contains("zh")
    }
}
