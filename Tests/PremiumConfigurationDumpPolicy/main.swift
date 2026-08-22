import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

expect(
    PremiumConfigurationDumpPolicy.shouldCapture(
        accountType: "premium",
        hasConfiguration: true,
        assignedValueCount: 1
    ),
    "A complete Premium configuration must be captured"
)

expect(
    PremiumConfigurationDumpPolicy.shouldCapture(
        accountType: " PREMIUM\n",
        hasConfiguration: true,
        assignedValueCount: 100
    ),
    "Premium account type matching must tolerate casing and whitespace"
)

let nonPremiumAccountTypes: [String?] = [nil, "free", "unlimited"]
for accountType in nonPremiumAccountTypes {
    expect(
        !PremiumConfigurationDumpPolicy.shouldCapture(
            accountType: accountType,
            hasConfiguration: true,
            assignedValueCount: 100
        ),
        "Non-Premium accounts must never produce the replacement dump"
    )
}

expect(
    !PremiumConfigurationDumpPolicy.shouldCapture(
        accountType: "premium",
        hasConfiguration: false,
        assignedValueCount: 100
    ),
    "A missing ResolveConfiguration must not be captured"
)

expect(
    !PremiumConfigurationDumpPolicy.shouldCapture(
        accountType: "premium",
        hasConfiguration: true,
        assignedValueCount: 0
    ),
    "An empty ResolveConfiguration must not be captured"
)

expect(
    PremiumConfigurationDumpPolicy.fileName(spotifyVersion: "9.1.76 beta/1")
        == "resolveconfiguration-spotify-9.1.76_beta_1-premium.bnk",
    "The dump filename must be safe to export"
)

print("PremiumConfigurationDumpPolicy tests passed")
