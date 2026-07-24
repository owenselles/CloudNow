@testable import CloudNow
import Foundation
import Testing

nonisolated struct StubbedHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]

    init(statusCode: Int = 200, data: Data = Data(), headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }

    init(statusCode: Int = 200, json: String, headers: [String: String] = [:]) {
        self.init(statusCode: statusCode, data: Data(json.utf8), headers: headers)
    }
}

actor RecordingHTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> StubbedHTTPResponse

    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index = recordedRequests.count
        recordedRequests.append(request)
        let stub = try await handler(request, index)
        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        ) else {
            throw TestTransportError.invalidHTTPResponse
        }
        return (stub.data, response)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

/// Kept separate so Sendable isolation inference does not apply to the actor declaration.
extension RecordingHTTPTransport: HTTPTransport {}

nonisolated enum TestTransportError: Error, Equatable {
    case unexpectedRequest(String)
    case invalidHTTPResponse
}

private final class NetworkingFixtureBundleToken: NSObject {}

nonisolated enum NetworkingFixture {
    static func data(_ filename: String) throws -> Data {
        let bundle = Bundle(for: NetworkingFixtureBundleToken.self)
        let fileURL = URL(fileURLWithPath: filename)
        let name = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        let candidates = [
            bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "Networking/Fixtures"
            ),
            bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"),
            bundle.url(forResource: name, withExtension: fileExtension),
        ]
        return try Data(contentsOf: #require(
            candidates.compactMap(\.self).first,
            "Missing networking fixture \(filename)"
        ))
    }

    static func string(_ filename: String) throws -> String {
        try #require(
            String(data: data(filename), encoding: .utf8),
            "Networking fixture \(filename) is not UTF-8"
        )
    }
}

nonisolated func jsonObject(from request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody, "Request should contain a JSON body")
    return try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any],
        "Request body should be a JSON object"
    )
}

nonisolated func formValues(from request: URLRequest) throws -> [String: String] {
    let body = try #require(request.httpBody, "Request should contain a form body")
    let bodyString = try #require(String(data: body, encoding: .utf8))
    var components = URLComponents()
    components.percentEncodedQuery = bodyString.replacingOccurrences(of: "+", with: "%20")
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
        ($0.name, $0.value ?? "")
    })
}
