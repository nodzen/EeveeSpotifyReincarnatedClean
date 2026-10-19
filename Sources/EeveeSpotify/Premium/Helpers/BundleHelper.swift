import Foundation
import SwiftUI
import EeveeSpotifyC

private let tweakAnchor: @convention(c) () -> Void = {}

private func tweakDirectory() -> String? {
    var info = Dl_info()
    let pointer = unsafeBitCast(tweakAnchor, to: UnsafeRawPointer.self)
    guard dladdr(pointer, &info) != 0, let name = info.dli_fname else { return nil }
    return (String(cString: name) as NSString).deletingLastPathComponent
}

class BundleHelper {
    private let bundleName = "EeveeSpotify"
    
    // Make properties optional to prevent init crash
    private var bundle: Bundle?
    private var enBundle: Bundle?
    
    static let shared = BundleHelper()
    
    private init() {
        // Try locating in main bundle first
        if let path = Bundle.main.path(forResource: bundleName, ofType: "bundle"),
           let b = Bundle(path: path) {
            self.bundle = b
            NSLog("[EeveeSpotify] Loaded bundle from main bundle: \(path)")
        }
        // Injected builds keep the bundle next to the tweak dylib.
        else if let directory = tweakDirectory(),
                let b = Bundle(path: directory + "/\(bundleName).bundle") {
            self.bundle = b
            NSLog("[EeveeSpotify] Loaded bundle next to dylib: \(directory)")
        }
        // If not found, try locating in file system (jailbreak path)
        else {
            let jbPath = EeveeJBRootPath("/Library/Application Support/\(bundleName).bundle")
            if let b = Bundle(path: jbPath) {
                self.bundle = b
                NSLog("[EeveeSpotify] Loaded bundle from filesystem: \(jbPath)")
            } else {
                NSLog("[EeveeSpotify] ERROR: Could not find EeveeSpotify.bundle!")
                self.bundle = nil
            }
        }
        
        // Load English localization if available
        if let b = self.bundle, let enPath = b.path(forResource: "en", ofType: "lproj"),
           let enB = Bundle(path: enPath) {
            self.enBundle = enB
        } else {
            NSLog("[EeveeSpotify] WARNING: Could not load en.lproj from bundle")
            self.enBundle = nil
        }
    }
    
    func uiImage(_ name: String) -> UIImage? {
        guard let bundle = self.bundle else { return nil }
        
        if let path = bundle.path(forResource: name, ofType: "png") {
            return UIImage(contentsOfFile: path)
        }
        return nil
    }
    
    func localizedString(_ key: String) -> String {
        guard let bundle = self.bundle else { return key }

        let value = bundle.localizedString(forKey: key, value: "No translation", table: nil)
        
        if value != "No translation" {
            return value
        }
        
        return enBundle?.localizedString(forKey: key, value: nil, table: nil) ?? key
    }
    
    func resolveConfiguration() throws -> ResolveConfiguration {
        let spotifyVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let resourceName = BundledConfigurationPolicy.resourceName(for: spotifyVersion)

        guard let bundle = self.bundle,
              let url = bundle.url(forResource: resourceName, withExtension: "bnk") else {
            throw NSError(domain: "EeveeSpotify", code: 404, userInfo: [NSLocalizedDescriptionKey: "Configuration not found"])
        }

        writeDebugLog("[CONFIG] Using \(resourceName).bnk for Spotify \(spotifyVersion)")
        
        return try ResolveConfiguration(
            serializedBytes: try Data(contentsOf: url)
        )
    }
}
