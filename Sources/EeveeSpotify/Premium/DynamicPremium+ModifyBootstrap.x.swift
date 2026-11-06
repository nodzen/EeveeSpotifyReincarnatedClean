import Orion

private func showHavePremiumPopUp() {
    PopUpHelper.showPopUp(
        delayed: true,
        message: "have_premium_popup".localized,
        buttonText: "OK".uiKitLocalized
    )
}

class SpotifySessionDelegateBootstrapHook: ClassHook<NSObject>, SpotifySessionDelegate {
    // 8.9.8 only. Newer versions use the shared SpotifyResponsePatcher through
    // SPTDataLoaderServiceHook; hooking both buffered and patched bootstrap twice.
    typealias Group = IOS14BootstrapGroup
    static let targetName = "SPTCoreURLSessionDataDelegate"
    
    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
    }
    
    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url ?? task.originalRequest?.url else {
            // Never swallow body bytes: the patched path may still need them.
            orig.URLSession(session, dataTask: task, didReceiveData: data)
            return
        }
        
        if url.isBootstrap {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }

        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
    
    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        guard let url = task.currentRequest?.url ?? task.originalRequest?.url else {
            // A task with no URL must still receive its completion, or Spotify
            // waits forever for the bootstrap response.
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }
        
        if error == nil && url.isBootstrap {
            guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
                orig.URLSession(session, task: task, didCompleteWithError: error)
                return
            }
            
            do {
                var bootstrapMessage = try BootstrapMessage(serializedBytes: buffer)
                
                if UserDefaults.patchType == .notSet {
                    if bootstrapMessage.attributes["type"]?.stringValue == "premium" {
                        UserDefaults.patchType = .disabled
                        showHavePremiumPopUp()
                    }
                    else {
                        UserDefaults.patchType = .requests
                        // Dispatch to main thread — calling activate() (method swizzling) from
                        // a URLSession delegate background thread while inside the method being
                        // swizzled is not thread-safe and causes a first-launch crash.
                        DispatchQueue.main.async { activatePremiumPatchingGroup() }
                    }
                    
                }
                
                if UserDefaults.patchType == .requests {
                    writeDebugLog("[BOOTSTRAP] Patching bootstrap UCS response")
                    UserDefaults.hasPatchedBootstrap = true
                    modifyRemoteConfiguration(&bootstrapMessage.ucsResponse)
                    
                    orig.URLSession(
                        session,
                        dataTask: task,
                        didReceiveData: try bootstrapMessage.serializedBytes()
                    )
                }
                else {
                    writeDebugLog("[BOOTSTRAP] Passing through unmodified bootstrap (patchType=\(UserDefaults.patchType))")
                    orig.URLSession(session, dataTask: task, didReceiveData: buffer)
                }
                
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            catch {
            }
        }
        
        orig.URLSession(session, task: task, didCompleteWithError: error)
    }
}
