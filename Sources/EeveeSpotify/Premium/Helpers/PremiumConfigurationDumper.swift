import Foundation
import UIKit

enum PremiumConfigurationDumper {
    private static let lock = NSLock()
    private static var didNotifyThisLaunch = false

    static var dumpURL: URL? {
        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let spotifyVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"

        return documentsURL.appendingPathComponent(
            PremiumConfigurationDumpPolicy.fileName(spotifyVersion: spotifyVersion),
            isDirectory: false
        )
    }

    static func captureIfEligible(_ response: UcsResponse) {
        let configuration = response.resolve.configuration
        let accountType = response.attributes.accountAttributes["type"]?.stringValue

        guard PremiumConfigurationDumpPolicy.shouldCapture(
            accountType: accountType,
            hasConfiguration: response.resolve.hasConfiguration,
            assignedValueCount: configuration.assignedValues.count
        ) else {
            return
        }

        do {
            let data = try configuration.serializedData()
            guard !data.isEmpty, let targetURL = dumpURL else { return }

            let shouldNotify = try { () -> Bool in
                lock.lock()
                defer { lock.unlock() }

                let alreadyMatches = (try? Data(contentsOf: targetURL)) == data
                if !alreadyMatches {
                    try data.write(to: targetURL, options: .atomic)
                }

                defer { didNotifyThisLaunch = true }
                return !didNotifyThisLaunch
            }()

            writeDebugLog(
                "[PremiumConfigDump] Captured \(configuration.assignedValues.count) values "
                + "(\(data.count) bytes) as \(targetURL.lastPathComponent)"
            )

            if shouldNotify {
                PopUpHelper.showPopUp(
                    delayed: true,
                    message: "premium_config_dump_saved".localized,
                    buttonText: "OK".uiKitLocalized
                )
            }
        }
        catch {
            writeDebugLog("[PremiumConfigDump] Failed to save configuration: \(error.localizedDescription)")
        }
    }

    static func shareDump() {
        guard let targetURL = dumpURL,
              FileManager.default.fileExists(atPath: targetURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: targetURL.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            PopUpHelper.showPopUp(
                message: "premium_config_dump_missing".localized,
                buttonText: "OK".uiKitLocalized
            )
            return
        }

        DispatchQueue.main.async {
            let activityController = UIActivityViewController(
                activityItems: [targetURL],
                applicationActivities: nil
            )

            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let rootController = scene.windows.first?.rootViewController else {
                return
            }

            var topController = rootController
            while let presentedController = topController.presentedViewController {
                topController = presentedController
            }

            if let popover = activityController.popoverPresentationController {
                popover.sourceView = topController.view
                popover.sourceRect = CGRect(
                    x: topController.view.bounds.midX,
                    y: topController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
            }

            topController.present(activityController, animated: true)
        }
    }
}
