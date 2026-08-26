import Foundation

/// Ephemeral, synchronized token storage for lyrics providers. The token is
/// never persisted and its contents are never written to logs.
enum SpotifyAccessTokenStore {
    private static let queue = DispatchQueue(label: "com.eeveespotify.spotify-token")
    private static var storage: String?

    static var value: String? {
        queue.sync { storage }
    }

    static func capture(from request: URLRequest) {
        guard let url = request.url,
              let host = url.host?.lowercased(),
              host == "api.spotify.com" || host.hasSuffix(".spotify.com"),
              let headers = request.allHTTPHeaderFields,
              let auth = headers.first(where: {
                  $0.key.caseInsensitiveCompare("Authorization") == .orderedSame
              })?.value,
              auth.hasPrefix("Bearer ") else {
            return
        }

        let token = String(auth.dropFirst(7))
        guard !token.isEmpty else { return }
        queue.sync { storage = token }

        if EeveeDebug.enabled {
            writeDebugLog("[TokenCapture] captured an ephemeral Spotify token from host \(host)")
        }
    }

    static func clear() {
        queue.sync { storage = nil }
    }
}
