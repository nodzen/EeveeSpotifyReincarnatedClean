import Foundation
import Orion

// Sibling delegate to SPTDataLoaderService. Some regions (e.g. gae2) ship
// bootstrap / customize / PAM responses through this delegate instead — without
// hooking both, server-rendered free-tier strings slip through.
class HttpClientURLSessionHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "Connectivity_HttpClientKit.HttpClientURLSession"

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        if let request = task.currentRequest {
            SpotifyAccessTokenStore.capture(from: request)
        }

        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        if let nativeResponse = LyricsResponseGate.take(for: task) {
            let buffer = URLSessionHelper.shared.obtainData(for: task)
            let originalLyrics = nativeResponse.statusCode == 200
                ? buffer.flatMap { try? Lyrics(serializedBytes: $0) } : nil
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                // A response always belongs to its URL, even after a skip.
                // Substituting the visible song here poisons Spotify's cache.
                let payload = (try? getLyricsDataForCurrentTrack(url.path, originalLyrics: originalLyrics))
                    ?? emptyLyricsData(originalLyrics: originalLyrics, trackIdentifier: extractTrackId(from: url.path))
                    ?? Data()
                DispatchQueue.main.async { [self] in
                    guard let synthetic = HTTPURLResponse(url: url, statusCode: 200,
                        httpVersion: "2.0", headerFields: ["Content-Type": "application/x-protobuf"]) else {
                        orig.URLSession(session, task: task, didCompleteWithError: error)
                        return
                    }
                    orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic,
                        completionHandler: { disposition in
                            DispatchQueue.main.async { [self] in
                                if disposition == .allow {
                                    orig.URLSession(session, dataTask: task, didReceiveData: payload)
                                }
                                orig.URLSession(session, task: task, didCompleteWithError: nil)
                                writeDebugLog("[LyricsDelivery] completed track=\(extractTrackId(from: url.path) ?? "?") task=\(task.taskIdentifier) bytes=\(payload.count) nativeColors=\(originalLyrics?.hasColors == true)")
                            }
                        })
                }
            }
            return
        }

        logSessionResponse(task, url: url, error: error)

        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.flush(task, url: url)
        }

        if SpotifyResponseBlockPolicy.shouldBlock(url) {
            orig.URLSession(session, dataTask: task, didReceiveData: SpotifyResponseBlockPolicy.responseData(for: url))
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        // A non-200 lyrics response may already have been replaced with a
        // synthetic 200 response and custom body in didReceiveResponse. Keep
        // the real URLSession completion as the single completion callback,
        // and discard any original error body buffered after the replacement.
        if SpotifyResponsePatcher.consumeSyntheticLyricsTask(task) {
            URLSessionHelper.shared.discardData(for: task)
            writeDebugLog("[HCUS] Completed synthetic lyrics response (taskId=\(task.taskIdentifier))")
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // marked for modify but no body bytes (0-byte/early-completion/redirect).
            // Always forward completion or Spotify hangs and gets watchdog-killed.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else if url.isLyrics {
                // A native-missing lyrics response can complete with zero body
                // bytes. Fetch the external source explicitly instead of
                // forwarding an empty Spotify response and stopping there.
                writeDebugLog("[HCUS] lyrics response had no body; starting external fetch path=\(url.path)")
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let requestedPayload = (try? getLyricsDataForCurrentTrack(url.path))
                        ?? emptyLyricsData(trackIdentifier: extractTrackId(from: url.path))
                        ?? Data()
                    let lyricsPayload = requestedPayload
                    DispatchQueue.main.async { [self] in
                        orig.URLSession(session, dataTask: task, didReceiveData: lyricsPayload)
                        orig.URLSession(session, task: task, didCompleteWithError: nil)
                    }
                }
            } else {
                // Some Spotify builds complete "modified" tasks with 0 body bytes.
                // We previously forwarded completion only, which can crash callers that
                // assume at least one didReceiveData before completion.
                writeDebugLog("[HCUS] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        // Publish the screen structure without waiting for external providers.
        // Playback prefetch warms lyrics independently; only the lyrics response
        // waits for its payload, never the rest of the Now Playing screen.
        if BaseLyricsGroup.isActive, ScrollsitaLyricsCardPatcher.shouldHandle(url),
           let trackID = ScrollsitaLyricsCardPatcher.responseTrackID(buffer, url: url) {
            prefetchLyricsIfNeeded(trackId: trackID)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let patched = (try? SpotifyResponsePatcher.patch(url: url, buffer: buffer))?.data ?? buffer
                DispatchQueue.main.async { [self] in
                    orig.URLSession(session, dataTask: task, didReceiveData: patched)
                    orig.URLSession(session, task: task, didCompleteWithError: nil)
                    ScrollsitaLyricsCardPatcher.noteScrollsitaPublished(trackID)
                    writeDebugLog("[LyricsDelivery] Scrollsita published track=\(trackID)")
                }
            }
            return
        }

        do {
            if url.isLyrics {
                let originalLyrics = try? Lyrics(serializedBytes: buffer)
                writeDebugLog("[HCUS] replacing lyrics body bytes=\(buffer.count) nativeLines=\(originalLyrics?.data.lines.count ?? -1) path=\(url.path)")

                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let requestedPayload = (try? getLyricsDataForCurrentTrack(
                        url.path,
                        originalLyrics: originalLyrics
                    ))
                        ?? emptyLyricsData(
                            originalLyrics: originalLyrics,
                            trackIdentifier: extractTrackId(from: url.path)
                        )
                        ?? Data()
                    let lyricsPayload = requestedPayload
                    DispatchQueue.main.async { [self] in
                        orig.URLSession(session, dataTask: task, didReceiveData: lyricsPayload)
                        orig.URLSession(session, task: task, didCompleteWithError: nil)
                    }
                }
                return
            }

            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[HCUS] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil — no transform, but didReceiveData already
            // suppressed the original. Replay or consumer hangs.
            orig.URLSession(session, dataTask: task, didReceiveData: buffer)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
        } catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304,
           let cached = SpotifyResponsePatcher.cachedCustomizeData {
            guard let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
            return
        }

        guard BaseLyricsGroup.isActive,
              let url = task.currentRequest?.url,
              url.isLyrics else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // Let URLSession drain the original body, but do not open Spotify's
        // renderer until its replacement is ready. The completion path keeps
        // the native palette and delivers response -> body -> completion.
        LyricsResponseGate.hold(response, for: task)
        handler(.allow)
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }
        if SpotifyResponseBlockPolicy.shouldBlock(url) { return }
        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.append(data, for: task)
        }
        if SpotifyResponsePatcher.shouldModify(url) {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }
        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
}
