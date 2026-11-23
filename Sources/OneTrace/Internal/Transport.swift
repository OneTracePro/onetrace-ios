import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HttpResult {
    let status: Int
    let body: String
    /// Response headers with lowercased names.
    let headers: [String: String]

    init(status: Int, body: String, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    var successful: Bool { (200..<300).contains(status) }

    /// The request may succeed later: no network, rate limit or a server error.
    var retryable: Bool { status == 0 || status == 429 || status >= 500 }
}

protocol Transport {
    /// Blocking POST: called from the SDK queue only.
    func post(_ path: String, _ body: [String: Any]) -> HttpResult

    /// Blocking GET: called from the SDK queue only.
    func get(_ path: String) -> HttpResult

    /// Blocking GET with request headers (`If-None-Match`): called from the SDK queue only.
    func get(_ path: String, headers: [String: String]) -> HttpResult
}

extension Transport {
    func get(_ path: String, headers: [String: String]) -> HttpResult {
        get(path)
    }
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

    func get(_ path: String, headers: [String: String]) -> HttpResult {
        send("GET", path, nil, headers)
    }

    private func send(_ method: String, _ path: String, _ data: Data?, _ headers: [String: String] = [:]) -> HttpResult {
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
        // A conditional request of our own: the 304 comes back to the SDK instead of a cached copy.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let done = DispatchSemaphore(value: 0)
        var result = HttpResult(status: 0, body: "")
        session.dataTask(with: request) { data, response, error in
            let http = response as? HTTPURLResponse
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? ""
            var fields: [String: String] = [:]
            http?.allHeaderFields.forEach { name, value in
                if let name = name as? String, let value = value as? String { fields[name.lowercased()] = value }
            }
            result = HttpResult(status: http?.statusCode ?? 0, body: text, headers: fields)
            done.signal()
        }.resume()
        done.wait()

        return result
    }
}
