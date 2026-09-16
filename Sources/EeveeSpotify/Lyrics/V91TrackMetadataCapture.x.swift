import Foundation

private final class TrackDetailsResultBox {
    private let lock = NSLock()
    private var value: (title: String, artist: String)?

    func store(title: String, artist: String) {
        lock.lock()
        value = (title, artist)
        lock.unlock()
    }

    func load() -> (title: String, artist: String)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// Function to fetch track details using Spotify API if we have a token
func fetchTrackDetails(trackId: String, token: String) -> (title: String, artist: String)? {
    let urlString = "https://api.spotify.com/v1/tracks/\(trackId)"
    guard let url = URL(string: urlString) else { return nil }
    
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 3.0
    
    let result = TrackDetailsResultBox()
    let semaphore = DispatchSemaphore(value: 0)
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        guard let data = data,
              error == nil,
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return
        }
        
        // Simple JSON parsing
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String,
           let artists = json["artists"] as? [[String: Any]],
           let firstArtist = artists.first,
           let artistName = firstArtist["name"] as? String {
            result.store(title: name, artist: artistName)
        }
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .now() + 3.0)
    
    return result.load()
}
