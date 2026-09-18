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
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        DispatchQueue.main.async { [self] in
                            writeDebugLog("[DL] Finished stale empty-body lyrics task without cancellation track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, dataTask: task, didReceiveData: emptyLyricsData() ?? Data())
                            orig.URLSession(session, task: task, didCompleteWithError: nil)
                        }
                        return
                    }
                    let lyricsPayload = (try? getLyricsDataForCurrentTrack(url.path))
                        ?? emptyLyricsData(trackIdentifier: extractTrackId(from: url.path))
                        ?? Data()
                    DispatchQueue.main.async { [self] in
                        guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                            writeDebugLog("[DL] Finished stale empty-body lyrics response without cancellation track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, dataTask: task, didReceiveData: emptyLyricsData() ?? Data())
                            orig.URLSession(session, task: task, didCompleteWithError: nil)
                            return
                        }
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
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        DispatchQueue.main.async { [self] in
                            writeDebugLog("[DL] Finished stale buffered lyrics task without cancellation track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, dataTask: task, didReceiveData: emptyLyricsData() ?? Data())
                            orig.URLSession(session, task: task, didCompleteWithError: nil)
                        }
                        return
                    }
                    let lyricsPayload = (try? getLyricsDataForCurrentTrack(
                        url.path,
                        originalLyrics: originalLyrics
                    ))
                        ?? emptyLyricsData(
                            originalLyrics: originalLyrics,
                            trackIdentifier: extractTrackId(from: url.path)
                        )
                        ?? Data()
                    DispatchQueue.main.async { [self] in
                        guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                            writeDebugLog("[DL] Finished stale buffered lyrics response without cancellation track=\(extractTrackId(from: url.path) ?? "unknown")")
                            orig.URLSession(session, dataTask: task, didReceiveData: emptyLyricsData() ?? Data())
                            orig.URLSession(session, task: task, didCompleteWithError: nil)
                            return
                        }
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

        // Feed every replacement through one normal successful response. In
        // particular, never answer a superseded track with `.cancel`: Spotify
        // 9.1.80 treats that as a transport failure and stops creating further
        // color-lyrics tasks until the process is restarted.
        //
        // The body is forwarded from the wrapped response disposition callback
        // so Spotify has accepted the synthetic response before it sees data.
        let deliverSyntheticLyrics = { [self] (lyricsData: Data, reason: String) in
            guard let synthetic = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "2.0",
                headerFields: ["Content-Type": "application/x-protobuf"]
            ) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }

            SpotifyResponsePatcher.markSyntheticLyricsTask(task)
            orig.URLSession(
                session,
                dataTask: task,
                didReceiveResponse: synthetic,
                completionHandler: { disposition in
                    let finish = { [self] in
                        handler(disposition)
                        if disposition == .allow {
                            self.orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
                        }
                    }
                    if Thread.isMainThread {
                        finish()
                    } else {
                        DispatchQueue.main.async(execute: finish)
                    }
                }
            )
            writeDebugLog("[DL] Delivered synthetic lyrics response reason=\(reason) task=\(task.taskIdentifier)")
        }

        // Spotify 9.1.80 can return native lyrics with HTTP 200 even when
        // replacement is enabled. Delivering our body after the native
        // response has already been opened leaves the lower card stale until
        // it is reopened, so hold the response until the custom payload is
        // ready.
        if response.statusCode == 200 {
            writeDebugLog("[DL] Holding native 200 lyrics response (taskId=\(task.taskIdentifier))")

            DispatchQueue.global(qos: .userInitiated).async {
                guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                    DispatchQueue.main.async {
                        deliverSyntheticLyrics(
                            emptyLyricsData() ?? Data(),
                            "stale-native-200"
                        )
                    }
                    return
                }

                let lyricsData = (try? getLyricsDataForCurrentTrack(url.path))
                    ?? emptyLyricsData(trackIdentifier: extractTrackId(from: url.path))
                    ?? Data()

                DispatchQueue.main.async {
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        deliverSyntheticLyrics(
                            emptyLyricsData() ?? Data(),
                            "stale-native-200-after-fetch"
                        )
                        return
                    }
                    deliverSyntheticLyrics(lyricsData, "native-200-replacement")
                }
            }
            return
        }

        writeDebugLog("[DL] Replacing lyrics HTTP \(response.statusCode) (taskId=\(task.taskIdentifier))")

        DispatchQueue.global(qos: .userInitiated).async {
            guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                DispatchQueue.main.async {
                    deliverSyntheticLyrics(
                        emptyLyricsData() ?? Data(),
                        "stale-http-\(response.statusCode)"
                    )
                }
                return
            }
            let data = try? getLyricsDataForCurrentTrack(url.path)

            guard let lyricsData = data else {
                DispatchQueue.main.async {
                    guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                        deliverSyntheticLyrics(
                            emptyLyricsData() ?? Data(),
                            "stale-failed-provider"
                        )
                        return
                    }
                    deliverSyntheticLyrics(
                        emptyLyricsData(trackIdentifier: extractTrackId(from: url.path)) ?? Data(),
                        "provider-failed"
                    )
                }
                return
            }

            DispatchQueue.main.async {
                guard ScrollsitaLyricsCardPatcher.shouldDeliverLyricsResponse(url) else {
                    deliverSyntheticLyrics(
                        emptyLyricsData() ?? Data(),
                        "stale-provider-result"
                    )
                    return
                }
                deliverSyntheticLyrics(lyricsData, "http-\(response.statusCode)-replacement")
            }
        }
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
