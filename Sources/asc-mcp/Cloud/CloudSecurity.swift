import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Cryptographic helpers for opaque credentials and PKCE.
enum CloudSecurity {
    /// Generate an opaque token from the platform cryptographic random generator.
    /// - Returns: URL-safe, 256-bit random credential.
    /// - Throws: Never.
    static func token() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64URLEncodedString() } }

    /// Hash a credential before persisting it.
    /// - Returns: Lowercase SHA-256 digest.
    /// - Throws: Never.
    static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Compare credential hashes without early exit on differing bytes.
    /// - Returns: True when both values are equal.
    /// - Throws: Never.
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(hash(lhs).utf8), b = Array(hash(rhs).utf8)
        return zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Compute the OAuth PKCE S256 challenge.
    /// - Returns: URL-safe SHA-256 challenge.
    /// - Throws: Never.
    static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString() }

    /// Parse a query or form without accepting ambiguous duplicate parameters.
    /// - Returns: Decoded form fields.
    /// - Throws: CloudFailure for duplicate or malformed fields.
    static func form(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  result[key] == nil else { throw CloudFailure(status: 400, message: "Invalid or duplicate form field") }
            result[key] = value
        }
        return result
    }

    /// Escape user-derived text rendered in the owner portal.
    /// - Returns: HTML-safe text.
    /// - Throws: Never.
    static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Serialize a registered OAuth redirect's origin as one safe CSP source.
    /// - Returns: Scheme, ASCII host and optional port, without path, query or wildcards.
    /// - Throws: CloudFailure when the URL cannot be represented as a literal HTTP(S) CSP source.
    static func cspOrigin(_ redirectURI: String) throws -> String {
        guard let url = URL(string: redirectURI), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]".contains($0)) }) else {
            throw CloudFailure(status: 400, message: "Invalid OAuth redirect origin")
        }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return scheme + "://" + authority + (url.port.map { ":\($0)" } ?? "")
    }
}

struct CloudFailure: Error, Sendable {
    let status: Int
    let message: String
}

struct CloudPrincipal: Sendable, Codable {
    let grantID: String
    let scopes: Set<String>
    var canWrite: Bool { scopes.contains("asc:write") }
    var canAdmin: Bool { scopes.contains("asc:admin") }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
