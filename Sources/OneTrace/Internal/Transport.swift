import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HttpResult {
    let status: Int
    let body: String

    var successful: Bool { (200..<300).contains(status) }

    /// The request may succeed later: no network, rate limit or a server error.
    var retryable: Bool { status == 0 || status == 429 || status >= 500 }
}

protocol Transport {
    /// Blocking POST: called from the SDK queue only.
    func post(_ path: String, _ body: [String: Any]) -> HttpResult

    /// Blocking GET: called from the SDK queue only.
    func get(_ path: String) -> HttpResult
}

/// JSON over HTTPS with the write key, `URLSession` only.
final class URLSessionTransport: Transport {
    private let apiURL: String
    private let writeKey: String
    private let userAgent: String
    private let session: URLSession

    init(apiURL: String, writeKey: String, userAgent: String) {
        self.apiURL = apiURL
        self.writeKey = writeKey
        self.userAgent = userAgent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func post(_ path: String, _ body: [String: Any]) -> HttpResult {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return HttpResult(status: 0, body: "invalid request")
        }

        return send("POST", path, data)
    }

    func get(_ path: String) -> HttpResult {
        send("GET", path, nil)
    }

    private func send(_ method: String, _ path: String, _ data: Data?) -> HttpResult {
        guard let url = URL(string: apiURL + path) else {
            return HttpResult(status: 0, body: "invalid request")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        if data != nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let done = DispatchSemaphore(value: 0)
        var result = HttpResult(status: 0, body: "")
        session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? ""
            result = HttpResult(status: status, body: text)
            done.signal()
        }.resume()
        done.wait()

        return result
    }
}
