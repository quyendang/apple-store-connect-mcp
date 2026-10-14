import Foundation
import Hummingbird
import HTTPTypes
import Logging
import MCP

/// Native Swift HTTP host for the existing MCP worker graph.
struct CloudHTTPApplication: Sendable {
    let configuration: CloudConfiguration
    let oauth: CloudOAuth
    let runtime: CloudRuntime

    /// Route public discovery, OAuth, health, asset uploads and authenticated MCP requests.
    /// - Returns: HTTP JSON, HTML or streaming SSE responses.
    /// - Throws: Never; errors are converted into bounded, sanitized responses.
    func handle(_ request: Hummingbird.Request) async -> Response {
        do {
            let response = try await route(request)
            return secure(response, origin: request.headers[HTTPField.Name("Origin")!], path: request.uri.path)
        } catch let error as CloudFailure {
            var response = json(status: error.status, object: ["error": error.message])
            if error.status == 401 { response.headers[HTTPField.Name("WWW-Authenticate")!] = "Bearer resource_metadata=\"\(configuration.publicURL)/.well-known/oauth-protected-resource\"" }
            return secure(response, origin: request.headers[HTTPField.Name("Origin")!], path: request.uri.path)
        } catch let error as HTTPError {
            return secure(json(status: error.status.code, object: ["error": "Invalid or oversized request"]), origin: nil, path: request.uri.path)
        } catch {
            print("Cloud request failed: \(Redactor.redact(error.localizedDescription))", to: &standardError)
            return secure(json(status: 500, object: ["error": "Request failed; inspect the operation before retrying a write"]), origin: nil, path: request.uri.path)
        }
    }

    private func route(_ request: Hummingbird.Request) async throws -> Response {
        let path = request.uri.path
        let method = request.method.rawValue
        if method == "GET", ["/health/live", "/health/ready"].contains(path) {
            return json(object: ["status": "ok", "transport": "native-swift-http", "version": ServerVersion.current])
        }
        if let origin = request.headers[HTTPField.Name("Origin")!], !configuration.allowedOrigins.contains(origin) { throw CloudFailure(status: 403, message: "Origin not allowed") }
        if method == "OPTIONS" {
            return Response(status: .noContent, headers: [HTTPField.Name("Access-Control-Allow-Methods")!: "POST, GET, DELETE, OPTIONS", HTTPField.Name("Access-Control-Allow-Headers")!: "Authorization, Content-Type, Accept, MCP-Session-Id, MCP-Protocol-Version, Last-Event-ID"])
        }
        if method == "GET", path == "/" {
            return html("<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>App Store Connect MCP</title><body><h1>App Store Connect MCP</h1><p>Native Swift Streamable HTTP endpoint: <code>/mcp</code></p><p>Connect using OAuth. All original App Store Connect workers are preserved. Assets and jobs use private persistent storage.</p></body></html>")
        }
        if method == "GET", ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"].contains(path) {
            return json(object: ["resource": configuration.publicURL + "/mcp", "authorization_servers": [configuration.publicURL], "scopes_supported": ["asc:read", "asc:write", "asc:admin", "offline_access"]])
        }
        if method == "GET", path == "/.well-known/oauth-authorization-server" { return data(try await oauth.metadata()) }
        if method == "POST", path == "/oauth/register" { return data(try await oauth.register(body(request, limit: 16384)), status: 201) }
        if method == "GET", path == "/oauth/authorize" {
            let page = try await oauth.authorizationPage(CloudSecurity.form(request.uri.query ?? ""))
            var response = html(page.html)
            // Browsers enforce form-action on redirects too. Only this validated callback origin is added.
            response.headers[HTTPField.Name("Content-Security-Policy")!] = contentSecurityPolicy(redirectOrigin: page.redirectOrigin)
            return response
        }
        if method == "POST", path == "/oauth/authorize" {
            let fields = try CloudSecurity.form(String(decoding: await body(request, limit: 16384), as: UTF8.self))
            let url = try await oauth.authorize(fields, remoteKey: "owner")
            return Response(status: .seeOther, headers: [.location: url])
        }
        if method == "POST", path == "/oauth/token" {
            let fields = try CloudSecurity.form(String(decoding: await body(request, limit: 16384), as: UTF8.self))
            return data(try await oauth.exchange(fields))
        }
        if method == "POST", path == "/oauth/revoke" {
            let fields = try CloudSecurity.form(String(decoding: await body(request, limit: 16384), as: UTF8.self))
            try await oauth.revoke(fields)
            return json(object: [:])
        }
        if path.hasPrefix("/upload/"), let ticket = path.split(separator: "/").last, ticket.count <= 100 {
            if method == "GET" { return html(try await runtime.files.page(ticket: String(ticket))) }
            if method == "POST" { return data(try await runtime.files.upload(ticket: String(ticket), request: request)) }
        }
        guard path == "/mcp" else { throw CloudFailure(status: 404, message: "Not found") }
        guard let principal = await oauth.authenticate(request.headers[.authorization]) else { throw CloudFailure(status: 401, message: "Authentication required") }
        guard ["POST", "GET", "DELETE"].contains(method) else { return Response(status: .methodNotAllowed, headers: [.allow: "POST, GET, DELETE"]) }
        let input = method == "POST" ? try await body(request, limit: 2 * 1024 * 1024) : nil
        let bodyVersion = input.flatMap { try? JSONDecoder().decode(Value.self, from: $0).objectValue?["params"]?.objectValue?["_meta"]?.objectValue?["io.modelcontextprotocol/protocolVersion"]?.stringValue }
        if request.headers[HTTPField.Name("MCP-Protocol-Version")!] == CloudModernRPC.version || bodyVersion != nil {
            guard method == "POST", let input else { return Response(status: .methodNotAllowed, headers: [.allow: "POST"]) }
            return try await CloudModernRPC.handle(input: input, request: request, runtime: runtime, principal: principal)
        }
        let session: CloudRuntime.Session
        if let id = request.headers[HTTPField.Name("MCP-Session-Id")!] {
            session = try await runtime.session(id: id, principal: principal)
        } else {
            guard method == "POST", let input,
                  let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
                  object["jsonrpc"] as? String == "2.0", object["method"] as? String == "initialize", object["id"] != nil else { throw CloudFailure(status: 400, message: "Initialize first, then send MCP-Session-Id on subsequent requests") }
            session = try await runtime.createSession(principal: principal)
        }
        var headers: [String: String] = [:]
        for field in request.headers { headers[field.name.rawName] = field.value }
        let response = await session.transport.handleRequest(MCP.HTTPRequest(method: method, headers: headers, body: input, path: "/mcp"))
        if method == "DELETE", response.statusCode == 200 { await runtime.removeSession(id: session.id) }
        if method == "POST", response.statusCode >= 400,
           request.headers[HTTPField.Name("MCP-Session-Id")!] == nil { await runtime.removeSession(id: session.id) }
        return adapt(response)
    }

    private func body(_ request: Hummingbird.Request, limit: Int) async throws -> Data {
        let buffer = try await request.body.collect(upTo: limit)
        return Data(buffer.readableBytesView)
    }
    private func adapt(_ response: MCP.HTTPResponse) -> Response {
        var fields = HTTPFields()
        for (name, value) in response.headers where name.lowercased() != "connection" { if let name = HTTPField.Name(name) { fields[name] = value } }
        if case .stream(let stream, _) = response {
            fields[HTTPField.Name("X-Accel-Buffering")!] = "no"
            let body = ResponseBody { writer in
                let (events, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
                let pump = Task {
                    do {
                        for try await event in stream {
                            if case .dropped = continuation.yield(event) { throw CloudFailure(status: 503, message: "SSE consumer too slow; resume or inspect before retrying") }
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                let heartbeat = Task {
                    do {
                        // Heartbeats avoid idle disconnects; streams still respect Railway's total duration limit.
                        for _ in 0..<56 {
                            try await Task.sleep(for: .seconds(15))
                            _ = continuation.yield(Data(": heartbeat\n\n".utf8))
                        }
                        continuation.finish()
                    } catch { }
                }
                defer { pump.cancel(); heartbeat.cancel(); continuation.finish() }
                for try await event in events { try await writer.write(ByteBuffer(bytes: event)) }
                try await writer.finish(nil)
            }
            return Response(status: .init(code: response.statusCode), headers: fields, body: body)
        }
        return Response(status: .init(code: response.statusCode), headers: fields, body: ResponseBody(byteBuffer: ByteBuffer(bytes: response.bodyData ?? Data())))
    }
    private func json(status: Int = 200, object: [String: Any]) -> Response {
        data((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8), status: status)
    }
    private func data(_ bytes: Data, status: Int = 200) -> Response {
        Response(status: .init(code: status), headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: bytes)))
    }
    private func html(_ text: String) -> Response {
        Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8"], body: .init(byteBuffer: ByteBuffer(string: text)))
    }
    private func contentSecurityPolicy(redirectOrigin: String? = nil) -> String {
        let formAction = ["'self'", redirectOrigin].compactMap { $0 }.joined(separator: " ")
        return "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; form-action \(formAction); frame-ancestors 'none'; base-uri 'none'"
    }
    private func secure(_ response: Response, origin: String?, path: String) -> Response {
        var response = response
        response.headers[.cacheControl] = "no-store"
        response.headers[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
        // HTML form navigation uses the referrer policy when serializing Origin.
        // no-referrer makes even a same-origin POST send Origin: null, blocking owner login.
        // same-origin preserves the login POST's origin without leaking the OAuth query to the callback.
        response.headers[HTTPField.Name("Referrer-Policy")!] = path == "/oauth/authorize" ? "same-origin" : "no-referrer"
        let policyHeader = HTTPField.Name("Content-Security-Policy")!
        response.headers[policyHeader] = response.headers[policyHeader] ?? contentSecurityPolicy()
        if let origin, configuration.allowedOrigins.contains(origin) {
            response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] = origin
            response.headers[HTTPField.Name("Access-Control-Expose-Headers")!] = "MCP-Session-Id, WWW-Authenticate"
            response.headers[.vary] = "Origin"
        }
        return response
    }
}

/// Run a native HTTP MCP server listening on Railway's PORT, preserving stdio as a separate mode.
/// - Returns: After graceful HTTP server shutdown.
/// - Throws: Configuration, storage, bind or server-lifecycle errors.
func runCloudApplication(options: AppRuntimeOptions) async throws {
    let configuration = try CloudConfiguration()
    // Validate the deployed resource bundle before reporting readiness or serving credentials.
    _ = try ASCOperationManifestBundle.loadBundled()
    let oauth = try CloudOAuth(configuration: configuration)
    let runtime = try CloudRuntime(configuration: configuration, options: options)
    let host = CloudHTTPApplication(configuration: configuration, oauth: oauth, runtime: runtime)
    let router = Router()
    let paths: [RouterPath] = ["/", "/health/live", "/health/ready", "/mcp", "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server", "/oauth/register", "/oauth/authorize", "/oauth/token", "/oauth/revoke", "/upload/{ticket}"]
    for path in paths {
        for method in [Hummingbird.HTTPRequest.Method.get, .post, .delete, .options] {
            router.on(path, method: method) { request, _ in await host.handle(request) }
        }
    }
    let app = Application(router: router, configuration: .init(address: .hostname("0.0.0.0", port: configuration.port)))
    print("Native Swift MCP HTTP server listening on port \(configuration.port); persistent data: \(configuration.dataDirectory.path)", to: &standardError)
    try await app.runService()
}
