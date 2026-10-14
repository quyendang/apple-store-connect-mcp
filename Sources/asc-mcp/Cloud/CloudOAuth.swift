import Foundation

/// Single-owner OAuth authorization server with PKCE and durable hashed credentials.
actor CloudOAuth {
    struct Client: Codable, Sendable {
        let clientID: String
        let redirectURIs: [String]
        let clientName: String
    }
    struct Code: Sendable {
        let clientID: String
        let redirectURI: String
        let challenge: String
        let scopes: Set<String>
        let resource: String
        let expires: Date
    }
    struct Credential: Codable, Sendable {
        let clientID: String
        let principal: CloudPrincipal
        let resource: String
        let expires: Date
        let refresh: Bool
    }
    struct State: Codable {
        var clients: [String: Client] = [:]
        var credentials: [String: Credential] = [:]
    }
    private let configuration: CloudConfiguration
    private let stateURL: URL
    private var state: State
    private var codes: [String: Code] = [:]
    private var approvals: [String: [String: String]] = [:]
    private var approvalExpiry: [String: Date] = [:]
    private var attempts: [String: [Date]] = [:]

    /// Load registered OAuth clients and hashed credentials from private persistent storage.
    /// - Returns: An OAuth service ready to authenticate the deployment owner.
    /// - Throws: File or decoding errors if existing state cannot be safely loaded.
    init(configuration: CloudConfiguration) throws {
        self.configuration = configuration
        stateURL = configuration.dataDirectory.appendingPathComponent("oauth.json")
        try FileManager.default.createDirectory(at: configuration.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        state = FileManager.default.fileExists(atPath: stateURL.path) ? try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) : State()
    }

    /// Publish OAuth discovery metadata for remote MCP hosts.
    /// - Returns: Authorization-server metadata supporting public clients and S256 PKCE.
    /// - Throws: Never.
    func metadata() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["issuer": configuration.publicURL,
         "authorization_endpoint": configuration.publicURL + "/oauth/authorize",
         "token_endpoint": configuration.publicURL + "/oauth/token",
         "registration_endpoint": configuration.publicURL + "/oauth/register",
         "revocation_endpoint": configuration.publicURL + "/oauth/revoke",
         "response_types_supported": ["code"], "grant_types_supported": ["authorization_code", "refresh_token"],
         "token_endpoint_auth_methods_supported": ["none"], "code_challenge_methods_supported": ["S256"],
         "authorization_response_iss_parameter_supported": true,
         "scopes_supported": ["asc:read", "asc:write", "asc:admin", "offline_access"]])
    }

    /// Register a public OAuth client, bounding inputs and allowed redirect schemes.
    /// - Returns: Client metadata including the generated client ID.
    /// - Throws: CloudFailure or persistence errors.
    func register(_ data: Data) throws -> Data {
        struct Registration: Decodable { let redirect_uris: [String]; let client_name: String?; let token_endpoint_auth_method: String? }
        let input: Registration
        do { input = try JSONDecoder().decode(Registration.self, from: data) }
        catch { throw CloudFailure(status: 400, message: "Invalid client metadata") }
        guard state.clients.count < 1000, !input.redirect_uris.isEmpty, input.redirect_uris.count <= 10,
              input.token_endpoint_auth_method == nil || input.token_endpoint_auth_method == "none",
              (input.client_name ?? "MCP client").count <= 200 else { throw CloudFailure(status: 400, message: "Unsupported public client metadata") }
        for value in input.redirect_uris {
            guard value.utf8.count < 2048, let url = URLComponents(string: value), url.user == nil, url.password == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")), url.host != nil else {
                throw CloudFailure(status: 400, message: "Redirect URI must use HTTPS or a loopback HTTP address")
            }
        }
        let client = Client(clientID: CloudSecurity.token(), redirectURIs: input.redirect_uris, clientName: input.client_name ?? "MCP client")
        state.clients[client.clientID] = client
        try persist()
        return try JSONSerialization.data(withJSONObject: ["client_id": client.clientID, "client_name": client.clientName, "redirect_uris": client.redirectURIs, "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]])
    }

    /// Prepare a bounded, expiring owner-consent flow after validating all OAuth parameters.
    /// - Returns: HTML with the registered client identity and requested permissions.
    /// - Throws: CloudFailure for invalid client, redirect, scopes, resource or PKCE challenge.
    func authorizationPage(_ parameters: [String: String]) throws -> String {
        cleanup()
        guard approvals.count < 200,
              let id = parameters["client_id"], let client = state.clients[id],
              let redirect = parameters["redirect_uri"], client.redirectURIs.contains(redirect),
              parameters["response_type"] == "code", parameters["code_challenge_method"] == "S256",
              let challenge = parameters["code_challenge"], challenge.utf8.count == 43,
              challenge.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              parameters["resource"] == configuration.publicURL + "/mcp",
              (parameters["state"] ?? "").utf8.count <= 2048 else { throw CloudFailure(status: 400, message: "Invalid OAuth authorization request") }
        let scopes = Set((parameters["scope"] ?? "asc:read asc:write asc:admin offline_access").split(separator: " ").map(String.init))
        guard !scopes.isEmpty, scopes.isSubset(of: ["asc:read", "asc:write", "asc:admin", "offline_access"]) else { throw CloudFailure(status: 400, message: "Unsupported OAuth scope") }
        let flow = CloudSecurity.token()
        var approved = parameters
        approved["scope"] = scopes.sorted().joined(separator: " ")
        approvals[flow] = approved
        approvalExpiry[flow] = Date().addingTimeInterval(600)
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Connect App Store Connect</title>
        <body style="font:17px system-ui;max-width:560px;margin:64px auto;padding:24px"><h1>Connect App Store Connect</h1>
        <p>Client: \(CloudSecurity.html(client.clientName))</p><p>Permissions: \(CloudSecurity.html(approved["scope"] ?? ""))</p>
        <p>Authorize access to the companies configured on this server. Write access can change or delete App Store Connect resources.</p>
        <form method="post" action="/oauth/authorize"><input type="hidden" name="flow" value="\(flow)">
        <label>Server owner password <input type="password" name="password" required autocomplete="current-password"></label>
        <p><button type="submit">Authorize connection</button></p></form></body></html>
        """
    }

    /// Authorize a PKCE code after owner login; consume the consent flow exactly once.
    /// - Returns: The exact registered redirect URI with code, state and issuer.
    /// - Throws: CloudFailure for invalid/expired flow or failed login, including throttled attempts.
    func authorize(_ input: [String: String], remoteKey: String) throws -> String {
        cleanup()
        let now = Date()
        attempts = attempts.filter { $0.value.contains { now.timeIntervalSince($0) < 60 } }
        var recent = (attempts[remoteKey] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 10, attempts.count < 10000 else { throw CloudFailure(status: 429, message: "Too many login attempts") }
        recent.append(now); attempts[remoteKey] = recent
        guard CloudSecurity.equal(input["password"] ?? "", configuration.adminPassword),
              let flow = input["flow"], let parameters = approvals.removeValue(forKey: flow) else { throw CloudFailure(status: 403, message: "Authorization failed or expired") }
        approvalExpiry.removeValue(forKey: flow)
        let code = CloudSecurity.token()
        codes[CloudSecurity.hash(code)] = Code(clientID: parameters["client_id"]!, redirectURI: parameters["redirect_uri"]!, challenge: parameters["code_challenge"]!, scopes: Set(parameters["scope"]!.split(separator: " ").map(String.init)), resource: parameters["resource"]!, expires: now.addingTimeInterval(120))
        var redirect = URLComponents(string: parameters["redirect_uri"]!)!
        var query = redirect.queryItems ?? []
        query += [URLQueryItem(name: "code", value: code), URLQueryItem(name: "iss", value: configuration.publicURL)]
        if let state = parameters["state"] { query.append(URLQueryItem(name: "state", value: state)) }
        redirect.queryItems = query
        return redirect.string!
    }

    /// Exchange a bound authorization code or rotate a refresh token.
    /// - Returns: Access token, optional rotated refresh token, lifetime and granted scopes.
    /// - Throws: CloudFailure for mismatched client/resource/PKCE or expired credentials; persistence errors.
    func exchange(_ input: [String: String]) throws -> Data {
        cleanup()
        guard let clientID = input["client_id"], state.clients[clientID] != nil,
              input["resource"] == configuration.publicURL + "/mcp" else { throw CloudFailure(status: 400, message: "invalid_grant") }
        let principal: CloudPrincipal
        if input["grant_type"] == "authorization_code" {
            guard let raw = input["code"], let code = codes.removeValue(forKey: CloudSecurity.hash(raw)), code.expires > Date(),
                  code.clientID == clientID, code.redirectURI == input["redirect_uri"], code.resource == input["resource"],
                  let verifier = input["code_verifier"], (43...128).contains(verifier.utf8.count),
                  verifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0)) }),
                  CloudSecurity.equal(CloudSecurity.challenge(verifier), code.challenge) else { throw CloudFailure(status: 400, message: "invalid_grant") }
            principal = CloudPrincipal(grantID: UUID().uuidString, scopes: code.scopes)
        } else if input["grant_type"] == "refresh_token" {
            guard let raw = input["refresh_token"], let old = state.credentials[CloudSecurity.hash(raw)], old.refresh, old.expires > Date(), old.clientID == clientID, old.resource == input["resource"] else { throw CloudFailure(status: 400, message: "invalid_grant") }
            principal = old.principal
            state.credentials.removeValue(forKey: CloudSecurity.hash(raw))
        } else { throw CloudFailure(status: 400, message: "unsupported_grant_type") }
        let access = CloudSecurity.token()
        state.credentials[CloudSecurity.hash(access)] = Credential(clientID: clientID, principal: principal, resource: configuration.publicURL + "/mcp", expires: Date().addingTimeInterval(3600), refresh: false)
        var response: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": 3600, "scope": principal.scopes.sorted().joined(separator: " ")]
        if principal.scopes.contains("offline_access") {
            let refresh = CloudSecurity.token()
            state.credentials[CloudSecurity.hash(refresh)] = Credential(clientID: clientID, principal: principal, resource: configuration.publicURL + "/mcp", expires: Date().addingTimeInterval(30 * 86400), refresh: true)
            response["refresh_token"] = refresh
        }
        try persist()
        return try JSONSerialization.data(withJSONObject: response)
    }

    /// Authenticate an OAuth bearer token or explicitly configured automation token.
    /// - Returns: The credential’s grant identity and permissions, or nil.
    /// - Throws: Never.
    func authenticate(_ authorization: String?) -> CloudPrincipal? {
        guard let authorization, authorization.hasPrefix("Bearer ") else { return nil }
        let raw = String(authorization.dropFirst(7))
        if let configured = configuration.bearerToken, CloudSecurity.equal(raw, configured) {
            return CloudPrincipal(grantID: "automation", scopes: ["asc:read", "asc:write", "asc:admin"])
        }
        guard let credential = state.credentials[CloudSecurity.hash(raw)], !credential.refresh, credential.expires > Date() else { return nil }
        return credential.principal
    }

    /// Revoke a token and every related credential in its OAuth grant.
    /// - Returns: Nothing; unknown credentials are deliberately indistinguishable.
    /// - Throws: Persistence errors.
    func revoke(_ input: [String: String]) throws {
        if let token = input["token"], let credential = state.credentials[CloudSecurity.hash(token)], credential.clientID == input["client_id"] {
            state.credentials = state.credentials.filter { $0.value.principal.grantID != credential.principal.grantID }
            try persist()
        }
    }

    private func cleanup() {
        let now = Date()
        codes = codes.filter { $0.value.expires > now }
        for id in approvalExpiry.keys where approvalExpiry[id]! <= now { approvals.removeValue(forKey: id); approvalExpiry.removeValue(forKey: id) }
        state.credentials = state.credentials.filter { $0.value.expires > now }
    }
    private func persist() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}
