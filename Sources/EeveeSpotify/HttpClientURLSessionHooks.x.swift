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
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        DispatchQueue.main.async { [self] in
                            writeDebugLog("[HCUS] Cancelled stale empty-body lyrics task track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, task: task, didCompleteWithError: URLError(.cancelled))
                        }
                        return
                    }
                    let lyricsPayload = (try? getLyricsDataForCurrentTrack(url.path))
                        ?? emptyLyricsData()
                        ?? Data()
                    DispatchQueue.main.async { [self] in
                        guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                            writeDebugLog("[HCUS] Dropped stale empty-body lyrics response track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, task: task, didCompleteWithError: URLError(.cancelled))
                            return
                        }
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

        do {
            if url.isLyrics {
                let originalLyrics = try? Lyrics(serializedBytes: buffer)
                writeDebugLog("[HCUS] replacing lyrics body bytes=\(buffer.count) nativeLines=\(originalLyrics?.data.lines.count ?? -1) path=\(url.path)")

                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        DispatchQueue.main.async { [self] in
                            writeDebugLog("[HCUS] Cancelled stale buffered lyrics task track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, task: task, didCompleteWithError: URLError(.cancelled))
                        }
                        return
                    }
                    let lyricsPayload = (try? getLyricsDataForCurrentTrack(
                        url.path,
                        originalLyrics: originalLyrics
                    ))
                        ?? emptyLyricsData(originalLyrics: originalLyrics)
                        ?? Data()
                    DispatchQueue.main.async { [self] in
                        guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                            writeDebugLog("[HCUS] Dropped stale buffered lyrics response track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, task: task, didCompleteWithError: URLError(.cancelled))
                            return
                        }
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

        // Spotify 9.1.80 can return native lyrics with HTTP 200 even when
        // replacement is enabled. If the response is opened immediately, the
        // lower card is built from the native body and does not observe our
        // later replacement until the user reopens it. Hold the response until
        // the external payload is ready, just like the 4xx/5xx path below.
        if response.statusCode == 200 {
            writeDebugLog("[HCUS] Holding native 200 lyrics response (taskId=\(task.taskIdentifier))")

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                    DispatchQueue.main.async {
                        writeDebugLog("[HCUS] Cancelled stale native 200 lyrics task track=\(extractTrackId(from: url.path) ?? "unknown")")
                        handler(.cancel)
                    }
                    return
                }

                let lyricsData = (try? getLyricsDataForCurrentTrack(url.path))
                    ?? emptyLyricsData()
                    ?? Data()

                DispatchQueue.main.async { [self] in
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        writeDebugLog("[HCUS] Dropped stale native 200 lyrics response track=\(extractTrackId(from: url.path) ?? "unknown")")
                        handler(.cancel)
                        return
                    }
                    guard let synthetic = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: "2.0",
                        headerFields: [:]
                    ) else {
                        handler(.cancel)
                        return
                    }

                    SpotifyResponsePatcher.markSyntheticLyricsTask(task)
                    orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
                    orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
                    writeDebugLog("[HCUS] Delivered external lyrics body for native 200 task=\(task.taskIdentifier)")
                }
            }
            return
        }

        writeDebugLog("[HCUS] Replacing lyrics HTTP \(response.statusCode) (taskId=\(task.taskIdentifier))")

        // Fetch on a background queue while holding the completion handler open.
        // Calling getLyricsDataForCurrentTrack synchronously here would block the
        // delegate queue and prevent subsequent delegate callbacks from firing.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                DispatchQueue.main.async {
                    writeDebugLog("[HCUS] Cancelled stale HTTP lyrics task track=\(extractTrackId(from: url.path) ?? "unknown")")
                    handler(.cancel)
                }
                return
            }
            let data = try? getLyricsDataForCurrentTrack(url.path)

            guard let lyricsData = data,
                  let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                DispatchQueue.main.async { [self] in
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        writeDebugLog("[HCUS] Cancelled stale failed lyrics task track=\(extractTrackId(from: url.path) ?? "unknown")")
                        handler(.cancel)
                        return
                    }
                    orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                }
                return
            }

            // The fetch above finishes on our global queue, but Spotify's new
            // lyrics UI keeps main-actor state. Deliver the replacement on the
            // main queue just like SPTDataLoaderServiceHook does; otherwise one
            // lyrics surface may parse the body while the NPV card never updates.
            DispatchQueue.main.async { [self] in
                guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                    writeDebugLog("[HCUS] Dropped stale lyrics response track=\(extractTrackId(from: url.path) ?? "unknown")")
                    handler(.cancel)
                    return
                }
                SpotifyResponsePatcher.markSyntheticLyricsTask(task)
                orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
                orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
                // The real URLSession callback supplies the only completion. Its
                // original error body is discarded by consumeSyntheticLyricsTask.
            }
        }
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
