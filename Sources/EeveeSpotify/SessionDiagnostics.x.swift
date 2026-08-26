import Foundation

/// Redacted session breadcrumb. It records only host/path, HTTP status and an
/// error code; never query parameters, headers or response bodies.
func logSessionResponse(_ task: URLSessionDataTask, url: URL, error: Error?) {
    guard url.isSessionDiagnosticRelated else { return }

    let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
    let errorSummary: String
    if let actualError = error {
        let nsError = actualError as NSError
        errorSummary = "\(nsError.domain)#\(nsError.code)"
    } else {
        errorSummary = "none"
    }

    let host = url.host ?? "?"
    writeDebugLog("[SESSION][RESPONSE] task=\(task.taskIdentifier) status=\(statusCode) host=\(host) path=\(url.path) error=\(errorSummary)")
}
