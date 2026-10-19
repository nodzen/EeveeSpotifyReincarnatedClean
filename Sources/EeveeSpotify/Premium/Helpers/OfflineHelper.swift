import Foundation

class OfflineHelper {
    static private let applicationSupportDirectory: URL? = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )
    .first
    
    static private let cachesDirectory: URL? = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
    ).first
    
    //
    
    static private var persistentCachePath: URL? {
        applicationSupportDirectory?.appendingPathComponent("PersistentCache")
    }
    
    static private var remoteConfigPath: URL? {
        applicationSupportDirectory?.appendingPathComponent("remote-config")
    }
    
    //
    
    static private func resetPersistentCache() throws {
        guard let path = persistentCachePath else { return }
        try FileManager.default.removeItem(at: path)
    }
    
    static private func resetRemoteConfig() throws {
        guard let path = remoteConfigPath else { return }
        try FileManager.default.removeItem(at: path)
    }
    
    static private func resetCaches() throws {
        guard let path = cachesDirectory else { return }
        try FileManager.default.removeItem(at: path)
    }
    
    //
    
    static func resetData(clearCaches: Bool = false) {
        try? resetPersistentCache()
        try? resetRemoteConfig()
        
        if clearCaches {
            try? resetCaches()
        }
    }

    /// Clears EeveeSpotify preferences plus cached tweak data, while keeping
    /// Spotify's own state intact. Recovery action for stale settings/caches
    /// left behind by older tweak versions.
    static func resetTweakSettings(clearCaches: Bool = true) {
        UserDefaults.resetEeveeSettings()
        try? resetPersistentCache()
        try? resetRemoteConfig()
        if clearCaches {
            try? resetCaches()
        }
    }
}
