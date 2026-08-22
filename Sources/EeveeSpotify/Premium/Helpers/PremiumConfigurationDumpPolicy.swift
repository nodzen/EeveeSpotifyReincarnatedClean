import Foundation

enum PremiumConfigurationDumpPolicy {
    static func shouldCapture(
        accountType: String?,
        hasConfiguration: Bool,
        assignedValueCount: Int
    ) -> Bool {
        guard hasConfiguration, assignedValueCount > 0 else { return false }

        return accountType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "premium"
    }

    static func fileName(spotifyVersion: String) -> String {
        let safeVersion = spotifyVersion.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character
                : "_"
        }

        return "resolveconfiguration-spotify-\(String(safeVersion))-premium.bnk"
    }
}
