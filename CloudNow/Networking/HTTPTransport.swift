import Foundation

/// Small request boundary used by service clients. Tests provide an actor-backed
/// implementation, while production keeps URLSession's cancellation behavior.
nonisolated protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)

    func data(
        for request: URLRequest,
        maximumResponseSize: Int
    ) async throws -> (Data, URLResponse)
}

nonisolated enum HTTPTransportError: Error, Equatable, Sendable {
    case invalidResponseSizeLimit
    case responseTooLarge
}

extension HTTPTransport {
    nonisolated func data(
        for request: URLRequest,
        maximumResponseSize: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumResponseSize >= 0 else {
            throw HTTPTransportError.invalidResponseSizeLimit
        }
        let result = try await data(for: request)
        guard result.0.count <= maximumResponseSize else {
            throw HTTPTransportError.responseTooLarge
        }
        return result
    }
}

nonisolated struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func data(
        for request: URLRequest,
        maximumResponseSize: Int
    ) async throws -> (Data, URLResponse) {
        guard maximumResponseSize >= 0 else {
            throw HTTPTransportError.invalidResponseSizeLimit
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength < 0
            || response.expectedContentLength <= Int64(maximumResponseSize)
        else {
            throw HTTPTransportError.responseTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumResponseSize else {
                throw HTTPTransportError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}

/// Returns useful server context without retaining credentials returned in an
/// OAuth or service error payload.
nonisolated func redactedHTTPBody(_ data: Data) -> String {
    guard !data.isEmpty else { return "(empty)" }
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
        return "(non-JSON response, \(data.count) bytes)"
    }
    let redacted = redactSensitiveValues(in: object)
    guard JSONSerialization.isValidJSONObject(redacted),
          let output = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys]),
          let description = String(data: output, encoding: .utf8)
    else {
        return "(unprintable JSON response, \(data.count) bytes)"
    }
    return description
}

private nonisolated func redactSensitiveValues(in value: Any) -> Any {
    if let dictionary = value as? [String: Any] {
        return Dictionary(uniqueKeysWithValues: dictionary.map { key, child in
            (key, isSensitiveHTTPField(key) ? "<redacted>" : redactSensitiveValues(in: child))
        })
    }
    if let array = value as? [Any] {
        return array.map(redactSensitiveValues)
    }
    return value
}

private nonisolated func isSensitiveHTTPField(_ key: String) -> Bool {
    let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
    return normalized == "authorization"
        || normalized == "code"
        || normalized.hasSuffix("_code")
        || normalized.contains("token")
        || normalized.contains("secret")
        || normalized.contains("password")
        || normalized.contains("credential")
        || normalized.contains("verifier")
}
