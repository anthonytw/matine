import Foundation

/// How this install introduces itself to Jellyfin. The device id is random per
/// install and names no person; Jellyfin shows `deviceName` in its dashboard.
public struct ClientIdentity: Sendable, Hashable {
    public var deviceId: String
    public var deviceName: String
    public var version: String

    public init(deviceId: String, deviceName: String, version: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.version = version
    }
}

public enum JellyfinError: Error, Sendable, Equatable {
    /// The token was refused (signed out on the server, or the password changed).
    case unauthorized
    /// Wrong user name or password at sign-in.
    case badCredentials
    case http(status: Int)
    case transport(code: Int)
    case decoding(String)
    /// The server address isn't `https://` or `http://` with a host.
    case unsupportedServer
}

/// The one door to the server. Every request goes through `send`, which sets
/// the auth header; the token never appears in a URL, so it can't leak into
/// logs or caches.
public struct JellyfinClient: Sendable {
    public let server: URL
    public let identity: ClientIdentity
    public let token: String?
    public let language: AppLanguage
    let transport: any HTTPTransport

    public init(
        server: URL,
        identity: ClientIdentity,
        token: String? = nil,
        language: AppLanguage = .default,
        transport: any HTTPTransport = URLSessionTransport.shared
    ) {
        self.server = server
        self.identity = identity
        self.token = token
        self.language = language
        self.transport = transport
    }

    func withToken(_ token: String?) -> JellyfinClient {
        JellyfinClient(server: server, identity: identity, token: token, language: language, transport: transport)
    }

    /// `MediaBrowser Client="…", Device="…", DeviceId="…", Version="…", Token="…"`.
    var authorizationHeader: String {
        var parts = [
            ("Client", "Matine"),
            ("Device", identity.deviceName),
            ("DeviceId", identity.deviceId),
            ("Version", identity.version),
        ]
        if let token { parts.append(("Token", token)) }
        return "MediaBrowser " + parts.map { "\($0.0)=\"\(Self.headerSafe($0.1))\"" }.joined(separator: ", ")
    }

    /// Jellyfin splits the header on commas and quotes; drop both, and anything
    /// outside printable ASCII, rather than send a header it misparses.
    static func headerSafe(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "," })
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue(language.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, status) = try await transport.perform(request)
        switch status {
        case 200..<300: return data
        case 401: throw JellyfinError.unauthorized
        default: throw JellyfinError.http(status: status)
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send("GET", path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JellyfinError.decoding("\(path): \(error)")
        }
    }

    /// Artwork URL. Jellyfin serves images without auth, so this carries no
    /// token and is safe to hand to an image loader or cache.
    public func imageURL(_ ref: ImageRef, maxHeight: Int) -> URL {
        url("/Items/\(ref.itemId)/Images/\(ref.kind.rawValue)", query: [
            URLQueryItem(name: "tag", value: ref.tag),
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "quality", value: "90"),
        ])
    }
}

/// The network seam: tests swap in a fake, the app and CLI use URLSession.
public protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, Int)
    /// A Range request: the status and Content-Range, and at most `maxBytes`
    /// of the body, which is read only for a 206; the rest is never fetched.
    func performRange(_ request: URLRequest, maxBytes: Int) async throws -> (Data, Int, String?)
}

public struct URLSessionTransport: HTTPTransport {
    /// API calls get their own session: ephemeral, so signed-in responses
    /// (watch history, pins) never land in the on-disk URL cache, and it
    /// refuses redirects that leave the server's origin, so the
    /// Authorization header can't follow one elsewhere. Posters load through
    /// `URLSession.shared` and its cache instead; their URLs carry no token.
    public static let shared = URLSessionTransport(session: URLSession(
        configuration: .ephemeral, delegate: SameOriginRedirects(), delegateQueue: nil
    ))
    let session: URLSession

    public init(session: URLSession) { self.session = session }

    /// A raw fetch through the same session (no cache, same-origin redirects
    /// only), for the CLI's stream probe.
    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await session.data(for: request)
        return (data, response as? HTTPURLResponse)
    }

    public func performRange(_ request: URLRequest, maxBytes: Int) async throws -> (Data, Int, String?) {
        guard maxBytes > 0 else { return (Data(), 0, nil) }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let range = http?.value(forHTTPHeaderField: "Content-Range")
            guard status == 206 else { return (Data(), status, range) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= maxBytes { break }
            }
            return (data, status, range)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw JellyfinError.transport(code: error.errorCode)
        }
    }

    public func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError {
            // A cancelled request is a cancelled task (a screen went away), not a lost connection.
            if error.code == .cancelled { throw CancellationError() }
            throw JellyfinError.transport(code: error.errorCode)
        }
    }
}

/// Follows a redirect only within the same scheme, host and port, or up from
/// `http` to `https` on the same host (a proxy that upgrades plain requests). Never down.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        Self.allows(from: task.originalRequest?.url, to: request.url) ? request : nil
    }

    static func allows(from: URL?, to: URL?) -> Bool {
        guard let from, let to else { return false }
        guard let source = origin(from), let target = origin(to) else { return false }
        if source == target { return true }
        return from.scheme?.lowercased() == "http" && to.scheme?.lowercased() == "https"
            && from.host?.lowercased() == to.host?.lowercased()
    }

    /// Scheme, lowercased host and effective port (`https://h` is `https://h:443`).
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }
}
