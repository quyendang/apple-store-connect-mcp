import Foundation
import MCP

/// Configuration for the single-owner native HTTP deployment.
struct CloudConfiguration: Sendable {
    let publicURL: String
    let port: Int
    let dataDirectory: URL
    let adminPassword: String
    let bearerToken: String?
    let companies: CompaniesConfig
    let allowedOrigins: Set<String>
    let maximumUploadBytes: Int
    let maximumSessions: Int

    /// Read cloud configuration without exposing credentials in diagnostics.
    /// - Returns: Validated public URL, credentials, storage paths and companies.
    /// - Throws: ASCError.configuration for missing or invalid configuration.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let url = environment["MCP_PUBLIC_URL"] ?? ""
        guard let components = URLComponents(string: url),
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1"].contains(components.host ?? "")),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ASCError.configuration("MCP_PUBLIC_URL must be an HTTPS origin without a path (HTTP localhost is allowed for testing)")
        }
        publicURL = url.hasSuffix("/") ? String(url.dropLast()) : url
        guard let value = Int(environment["PORT"] ?? "8080"), (1...65535).contains(value) else {
            throw ASCError.configuration("PORT must be between 1 and 65535")
        }
        port = value
        let password = environment["MCP_ADMIN_PASSWORD"] ?? ""
        guard password.utf8.count >= 24 else { throw ASCError.configuration("MCP_ADMIN_PASSWORD must contain at least 24 bytes") }
        adminPassword = password
        bearerToken = environment["MCP_BEARER_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        if let bearerToken, bearerToken.utf8.count < 32 { throw ASCError.configuration("MCP_BEARER_TOKEN must contain at least 32 bytes") }
        dataDirectory = URL(fileURLWithPath: environment["MCP_DATA_DIR"] ?? "./cloud-data", isDirectory: true).standardizedFileURL
        // Extra browser origins must never exclude the server's own owner-login portal.
        allowedOrigins = Set((environment["MCP_ALLOWED_ORIGINS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }).union([publicURL])
        maximumUploadBytes = Int(environment["MCP_MAX_UPLOAD_BYTES"] ?? "10737418240") ?? 10_737_418_240
        maximumSessions = Int(environment["MCP_MAX_SESSIONS"] ?? "32") ?? 32
        guard maximumUploadBytes > 0, (1...256).contains(maximumSessions) else { throw ASCError.configuration("Invalid upload/session limits") }
        if let json = environment["ASC_COMPANIES_JSON"] {
            do { companies = try JSONDecoder().decode(CompaniesConfig.self, from: Data(json.utf8)) }
            catch { throw ASCError.configuration("ASC_COMPANIES_JSON is not a valid company configuration") }
        } else {
            companies = try CompaniesManager().config
        }
        guard !companies.companies.isEmpty, Set(companies.companies.map(\.id)).count == companies.companies.count else {
            throw ASCError.configuration("Configure at least one company, with unique company IDs")
        }
        guard companies.defaultURL == "https://api.appstoreconnect.apple.com" else {
            throw ASCError.configuration("Cloud mode only sends Apple credentials to the official App Store Connect origin")
        }
    }
}
