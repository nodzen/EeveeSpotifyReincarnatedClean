import Foundation

/// Build/runtime switch for diagnostics that should not be active in a normal
/// release IPA. Build with `EEVEE_DEBUG=1` to compile a diagnostic variant.
/// A runtime override is kept for recovery on a jailbroken test device.
enum EeveeDebug {
    #if EEVEESPOTIFY_DEBUG
    static let buildEnabled = true
    #else
    static let buildEnabled = false
    #endif

    static var enabled: Bool {
        buildEnabled || eeveeEnvFlag("EEVEE_DEBUG_RUNTIME")
    }

    static var probesEnabled: Bool {
        enabled && !eeveeEnvFlag("EEVEE_DISABLE_PROBES")
    }

    /// The debug build retains the old broad synthetic-response behavior as a
    /// compatibility fallback. Release builds never use it as active policy.
    static var legacyResponseBlocksEnabled: Bool {
        #if EEVEESPOTIFY_DEBUG
        return !eeveeEnvFlag("EEVEE_DISABLE_LEGACY_RESPONSE_BLOCKS")
        #else
        return false
        #endif
    }
}

@inline(__always)
func eeveeEnvFlag(_ name: String) -> Bool {
    guard let value = getenv(name) else { return false }
    let normalized = String(cString: value).lowercased()
    return normalized == "1" || normalized == "true" || normalized == "yes" || normalized == "y"
}

private let eeveeDebugLogQueue = DispatchQueue(label: "com.eeveespotify.debug-log")
private let eeveeDebugLogMaximumSize: UInt64 = 512 * 1024

/// Detailed logs are debug-only, serialized, and capped so concurrent URL
/// session callbacks cannot corrupt or grow the temporary log indefinitely.
func writeDebugLog(_ message: String) {
    guard EeveeDebug.enabled else { return }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"
    NSLog("[EeveeSpotify] %@", message)

    eeveeDebugLogQueue.async {
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eeveespotify_debug.log")
        guard let data = logMessage.data(using: .utf8) else { return }

        let existingSize = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)
            .map { $0.uint64Value } ?? 0

        if existingSize >= eeveeDebugLogMaximumSize {
            try? data.write(to: logURL, options: .atomic)
            return
        }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }
}
