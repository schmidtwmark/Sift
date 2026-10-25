import Foundation
import os

public extension Error {
    /// Couldn't reach Fastmail just now (timeout, dropped or missing network,
    /// or Fastmail briefly unavailable). Trying again later is the fix.
    var isTransientNetworkFailure: Bool {
        if let error = self as? URLError {
            let transient: Set<URLError.Code> = [
                .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
                .callIsActive, .backgroundSessionWasDisconnected,
            ]
            return transient.contains(error.code)
        }
        if case .http(let status, _)? = self as? JMAPError { return [502, 503, 504].contains(status) }
        return false
    }
}

public enum JMAPError: Error, LocalizedError, Sendable, Equatable {
    /// HTTP 401: Fastmail didn't accept the credential at all.
    case unauthorized(detail: String?)
    /// HTTP 403: the credential is valid but not allowed to do this.
    case forbidden(detail: String?)
    case missingScopes([String])
    case http(status: Int, body: String)
    case method(type: String, description: String?)
    case missingResponse(String)
    case noMailAccount
    case badURL

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let detail):
            "Fastmail didn't accept this API token (HTTP 401)\(Self.quoted(detail)). API tokens start with “fmu1-”; app passwords made for IMAP or CalDAV won't work. Check the whole token was copied."
        case .forbidden(let detail):
            "Fastmail refused the request (HTTP 403)\(Self.quoted(detail)). The token may be missing the Email submission or Contacts scope."
        case .missingScopes(let scopes):
            "This API token doesn't include \(scopes.formatted(.list(type: .and))). In Fastmail, create a new token with Email, Email submission, and Contacts access."
        case .http(let status, let body): "Fastmail returned HTTP \(status). \(body.prefix(200))"
        case .method(let type, let description): "JMAP error \(type)\(description.map { ": \($0)" } ?? "")"
        case .missingResponse(let id): "Missing JMAP response for call \(id)."
        case .noMailAccount: "This Fastmail account has no mail account."
        case .badURL: "Fastmail returned a malformed URL."
        }
    }

    private static func quoted(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return ": “\(detail)”"
    }

    /// Fastmail's own explanation from an error response: RFC 7807 problem
    /// JSON (`detail`/`title`), or short plain text.
    static func serverDetail(from body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            for key in ["detail", "title", "description", "error"] {
                if let value = object[key] as? String, !value.isEmpty { return String(value.prefix(200)) }
            }
            return nil
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("<") else { return nil }
        return String(text.prefix(200))
    }
}

/// One JMAP method invocation: `[name, arguments, callId]`.
public struct MethodCall: Sendable, Encodable {
    public var name: String
    public var arguments: [String: JSONValue]
    public var id: String

    public init(_ name: String, _ arguments: [String: JSONValue], id: String) {
        self.name = name
        self.arguments = arguments
        self.id = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(name)
        try container.encode(arguments)
        try container.encode(id)
    }

    /// A result reference (`#name`) pointing at a path in an earlier call's result.
    public static func reference(to callId: String, name: String, path: String) -> JSONValue {
        ["resultOf": .string(callId), "name": .string(name), "path": .string(path)]
    }
}

public struct JMAPResponse: Sendable {
    struct Invocation: Sendable {
        var name: String
        var arguments: Data
        var id: String
    }

    var invocations: [Invocation]
    public var sessionState: String?

    /// Decodes the result of call `id`. When a call produces several responses
    /// (e.g. an implicit `Email/set` after `EmailSubmission/set`), the one whose
    /// name matches `name` wins.
    public func result<T: Decodable>(_ id: String, name: String? = nil, as type: T.Type = T.self) throws -> T {
        let matches = invocations.filter { $0.id == id }
        if let error = matches.first(where: { $0.name == "error" }) {
            let payload = try? JSONDecoder().decode([String: String].self, from: error.arguments)
            JMAPClient.log.error("JMAP method error for \(id, privacy: .public): \(String(decoding: error.arguments, as: UTF8.self), privacy: .public)")
            throw JMAPError.method(type: payload?["type"] ?? "unknown", description: payload?["description"])
        }
        guard let invocation = name.flatMap({ wanted in matches.first { $0.name == wanted } }) ?? matches.first else {
            throw JMAPError.missingResponse(id)
        }
        return try JMAPCoding.decoder.decode(T.self, from: invocation.arguments)
    }
}

/// A minimal JMAP client for Fastmail, authenticated with an API token.
public actor JMAPClient {
    public static let fastmailSessionURL = URL(string: "https://api.fastmail.com/jmap/session")!

    private let token: String
    private let sessionURL: URL
    private let urlSession: URLSession
    private var cachedSession: JMAPSession?

    public init(token: String, sessionURL: URL = JMAPClient.fastmailSessionURL, urlSession: URLSession = .shared) {
        self.token = token
        self.sessionURL = sessionURL
        self.urlSession = urlSession
    }

    public func session(refresh: Bool = false) async throws -> JMAPSession {
        if let cachedSession, !refresh { return cachedSession }
        let data = try await send(authorized(URLRequest(url: sessionURL)))
        let session = try JMAPCoding.decoder.decode(JMAPSession.self, from: data)
        cachedSession = session
        return session
    }

    public func accountId() async throws -> String {
        guard let id = try await session().mailAccountId else { throw JMAPError.noMailAccount }
        return id
    }

    public func perform(
        _ calls: [MethodCall],
        using capabilities: [String] = [JMAPCapability.core, JMAPCapability.mail]
    ) async throws -> JMAPResponse {
        struct Body: Encodable {
            var using: [String]
            var methodCalls: [MethodCall]
        }
        let session = try await session()
        var request = authorized(URLRequest(url: session.apiUrl))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JMAPCoding.encoder.encode(Body(using: capabilities, methodCalls: calls))
        let data = try await send(request)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = root["methodResponses"] as? [[Any]] else {
            throw JMAPError.http(status: 200, body: String(decoding: data, as: UTF8.self))
        }
        let invocations = try responses.compactMap { triple -> JMAPResponse.Invocation? in
            guard triple.count == 3, let name = triple[0] as? String, let id = triple[2] as? String else { return nil }
            let arguments = try JSONSerialization.data(withJSONObject: triple[1])
            return .init(name: name, arguments: arguments, id: id)
        }
        let sessionState = root["sessionState"] as? String
        if let sessionState, sessionState != session.state {
            cachedSession = nil
        }
        return JMAPResponse(invocations: invocations, sessionState: sessionState)
    }

    public func download(blobId: String, name: String = "blob", type: String = "application/octet-stream") async throws -> Data {
        let session = try await session()
        guard let url = session.downloadURL(accountId: try await accountId(), blobId: blobId, name: name, type: type) else {
            throw JMAPError.badURL
        }
        return try await send(authorized(URLRequest(url: url)))
    }

    public func upload(_ data: Data, type: String) async throws -> String {
        struct UploadResponse: Decodable { var blobId: String }
        let session = try await session()
        guard let url = session.uploadURL(accountId: try await accountId()) else { throw JMAPError.badURL }
        var request = authorized(URLRequest(url: url))
        request.httpMethod = "POST"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let response = try JMAPCoding.decoder.decode(UploadResponse.self, from: try await send(request))
        return response.blobId
    }

    /// Streams push notifications from the session's EventSource endpoint.
    /// The stream ends when the connection drops; callers reconnect.
    public func stateChanges() async throws -> AsyncThrowingStream<StateChange, Error> {
        let session = try await session()
        guard let url = session.eventSourceURL() else { throw JMAPError.badURL }
        var request = authorized(URLRequest(url: url))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60 * 60 * 24
        let (bytes, response) = try await urlSession.bytes(for: request)
        try check(response, body: Data())

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var event = ""
                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            dataLines.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                        }
                        // `lines` drops blank separators, so dispatch as soon as a data line completes a state event.
                        if event == "state", !dataLines.isEmpty {
                            let payload = Data(dataLines.joined(separator: "\n").utf8)
                            if let change = try? JMAPCoding.decoder.decode(StateChange.self, from: payload) {
                                continuation.yield(change)
                            }
                            event = ""
                            dataLines = []
                        } else if event != "state", !dataLines.isEmpty {
                            dataLines = []
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await urlSession.data(for: request)
        try check(response, body: data)
        return data
    }

    static let log = Logger(subsystem: "com.markschmidt.Sift", category: "jmap")

    private func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let detail = JMAPError.serverDetail(from: body)
        // Never logs headers, so the token stays out of the system log.
        Self.log.error("HTTP \(http.statusCode) for \(http.url?.path() ?? "?", privacy: .public): \(detail ?? "no detail", privacy: .public)")
        switch http.statusCode {
        case 401: throw JMAPError.unauthorized(detail: detail)
        case 403: throw JMAPError.forbidden(detail: detail)
        default: throw JMAPError.http(status: http.statusCode, body: detail ?? String(decoding: body.prefix(200), as: UTF8.self))
        }
    }
}
