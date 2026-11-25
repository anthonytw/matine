import Foundation
@testable import MatineKit

/// Answers requests from fixtures by path, and records what was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: Data = Data("{}".utf8)
        var delay: Duration = .zero
        /// Fail like a dropped network instead of answering.
        var unreachable = false
    }

    private let lock = NSLock()
    private var routes: [String: Response] = [:]
    private var log: [URLRequest] = []

    /// Answers `method path`, or with `parentId` only requests for that parent.
    func on(
        _ method: String, _ path: String, parentId: String? = nil, status: Int = 200,
        fixture: String? = nil, body: String? = nil, delay: Duration = .zero, unreachable: Bool = false
    ) {
        var response = Response(status: status, delay: delay, unreachable: unreachable)
        if let fixture { response.body = Self.fixture(fixture) }
        if let body { response.body = Data(body.utf8) }
        lock.withLock { routes[Self.key(method, path, parentId)] = response }
    }

    static func key(_ method: String, _ path: String, _ parentId: String?) -> String {
        "\(method) \(path)" + (parentId.map { "?parentId=\($0)" } ?? "")
    }

    var requests: [URLRequest] { lock.withLock { log } }

    /// Paths whose answer is the whole list: a request for a later page
    /// (`startIndex` above 0) gets an empty one.
    var singlePage: Set<String> = []

    /// Throws a `CancellationError` instead of answering (a screen went away mid-request).
    var cancelOnNextCall = false

    func perform(_ request: URLRequest) async throws -> (Data, Int) {
        if lock.withLock({ cancelOnNextCall }) { throw CancellationError() }
        let method = request.httpMethod ?? "GET", path = request.url!.path
        let response = lock.withLock { () -> Response? in
            log.append(request)
            return routes[Self.key(method, path, request.query("parentId"))] ?? routes[Self.key(method, path, nil)]
        }
        guard let response else { return (Data(), 404) }
        if lock.withLock({ singlePage.contains(path) }), let start = request.query("startIndex"), start != "0" {
            return (Data(#"{"Items":[]}"#.utf8), 200)
        }
        if response.delay > .zero { try await Task.sleep(for: response.delay) }
        if response.unreachable { throw JellyfinError.transport(code: URLError.notConnectedToInternet.rawValue) }
        return (response.body, response.status)
    }

    /// The Content-Range a 206 answers with: the range asked for, unless set.
    var contentRange: String?

    func performRange(_ request: URLRequest, maxBytes: Int) async throws -> (Data, Int, String?) {
        let (data, status) = try await perform(request)
        let asked = request.value(forHTTPHeaderField: "Range").map { "bytes " + $0.dropFirst("bytes=".count) + "/*" }
        return (status == 206 ? data.prefix(maxBytes) : Data(), status, lock.withLock { contentRange } ?? asked)
    }

    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

extension URLRequest {
    func query(_ name: String) -> String? {
        URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

let testServer = URL(string: "https://tv.example.test")!
let testIdentity = ClientIdentity(deviceId: "device-1", deviceName: "Apple TV", version: "0.1.0")

func makeClient(_ transport: FakeTransport, token: String? = "tok-123", language: AppLanguage = .spanish) -> JellyfinClient {
    JellyfinClient(server: testServer, identity: testIdentity, token: token, language: language, transport: transport)
}
