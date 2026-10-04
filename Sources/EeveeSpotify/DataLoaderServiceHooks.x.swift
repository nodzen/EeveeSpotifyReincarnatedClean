import Foundation
import Orion

// Spotify's primary URLSession delegate (wg-spclient: bootstrap, customize, PAM).
// Patching lives in SpotifyResponsePatcher so HttpClientURLSessionHook can share it.

class SPTDataLoaderServiceHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "SPTDataLoaderService"

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

        // 304 already served — suppress the second completion.
        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        if SpotifyResponsePatcher.consumeSyntheticLyricsTask(task) {
            URLSessionHelper.shared.discardData(for: task)
            writeDebugLog("[DL] Completed synthetic lyrics response (taskId=\(task.taskIdentifier))")
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // Customize 304 fallback — wg-spclient returned 304, no buffer
            // to patch, but we have a cached body from a prior 200.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else if url.isLyrics {
                // Spotify 9.1.x may complete a missing/native-empty lyrics
                // response without any body. Still fetch our source here;
                // otherwise tracks without Spotify lyrics never reach LRCLIB
                // or Genius at all.
                writeDebugLog("[DL] lyrics response had no body; starting external fetch path=\(url.path)")
                // Keep Spotify's URLSession delegate queue free while the
                // provider is doing network I/O. On Liked Songs this queue
                // also carries track-selection work, so a slow provider can
                // otherwise look like a frozen app.
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
                // Forwarding completion only can crash consumers that assume at least
                // one didReceiveData callback before completion.
                writeDebugLog("[DL] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                // Always forward completion; otherwise Spotify may hang and get watchdog-killed.
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
            // Lyrics — async fetch with 18s budget. When replacement is enabled,
            // do not replay Spotify's original body on failure: that response is
            // exactly what can reintroduce native lyrics alongside the custom UI.
            //
            // iOS 27 / Spotify 9.1.60 fix: Spotify's URLSession delegate handler for
            // didReceiveData now accesses @MainActor-isolated state. When we call orig.*
            // from the SPTDataLoaderService delegate queue (a background serial queue),
            // Swift's strict concurrency runtime trips _swift_task_checkIsolatedSwift and
            // kills the process with EXC_BREAKPOINT / SIGTRAP.
            //
            // Fix: dispatch the two orig.URLSession calls onto the main queue.
            // This matches the execution context Spotify's renderer expects and eliminates
            // the @MainActor isolation violation entirely.
            if url.isLyrics {
                let originalLyrics = try? Lyrics(serializedBytes: buffer)
                writeDebugLog("[DL] replacing lyrics body bytes=\(buffer.count) nativeLines=\(originalLyrics?.data.lines.count ?? -1) path=\(url.path)")

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
                writeDebugLog("[DL] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil but didReceiveData already suppressed the original —
            // replay the buffer or the consumer hangs (casita/browsita with no ad sections).
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
            // 304, but our cache holds the already-patched body; force 200 so the
            // consumer accepts the cached data we replay next.
            guard let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
            return
        }

        // Lyrics 4xx/5xx — replace with our custom fetch result so the
        // consumer doesn't show "no lyrics available".
        //
        // IMPORTANT: getLyricsDataForCurrentTrack is a blocking network call.
        // Calling it synchronously here deadlocks because this delegate queue is
        // also needed to deliver subsequent delegate callbacks (didReceiveData,
        // didCompleteWithError). The fix is to fetch on a background queue while
        // holding the URLSession completion handler open — URLSession won't
        // proceed until we call handler(.allow/.cancel), so we have time to fetch
        // and then deliver everything ourselves.
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

        // Suppress original data for endpoints we'll replace in
        // didCompleteWithError — otherwise the consumer sees both.
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
