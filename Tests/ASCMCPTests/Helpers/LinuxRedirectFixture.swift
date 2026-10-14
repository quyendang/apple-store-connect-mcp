#if os(Linux)
import Foundation
import Glibc
import Dispatch
@testable import asc_mcp

/// Real loopback HTTP fixture replacing unsupported URLProtocol redirect simulation on Linux.
final class LinuxRedirectFixture: @unchecked Sendable {
    private struct Counts: Sendable { var source = 0; var target = 0 }
    private let counts = PortableLockedState(initialState: Counts())
    private let descriptor: Int32
    let sourceURL: URL
    private let targetURL: URL
    static let body = Data("original redirect response".utf8)
    var sourceCount: Int { counts.withLock { $0.source } }
    var targetCount: Int { counts.withLock { $0.target } }

    init() throws {
        let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socket >= 0 else { throw FixtureFailure.socket }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glibc.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Glibc.listen(socket, 4) == 0 else { Glibc.close(socket); throw FixtureFailure.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        guard inspected == 0 else { Glibc.close(socket); throw FixtureFailure.socket }
        let port = UInt16(bigEndian: address.sin_port)
        descriptor = socket
        sourceURL = URL(string: "http://127.0.0.1:\(port)/source")!
        targetURL = URL(string: "http://127.0.0.1:\(port)/target")!
        DispatchQueue(label: "asc.redirect.fixture").async { [self] in serve() }
    }

    func stop() { _ = shutdown(descriptor, Int32(SHUT_RDWR)); Glibc.close(descriptor) }

    private func serve() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var bytes = [UInt8](repeating: 0, count: 16384)
            var received = Data()
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
            while received.count < 65536 {
                let size = recv(client, &bytes, bytes.count, 0)
                guard size > 0 else { break }
                received.append(contentsOf: bytes.prefix(size))
                if let boundary = received.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: received[..<boundary.lowerBound], as: UTF8.self)
                    let field = header.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    let bodySize = field.flatMap { Int($0.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)) } ?? 0
                    if received.count >= boundary.upperBound + bodySize { break }
                }
            }
            if !received.isEmpty {
                let request = String(decoding: received, as: UTF8.self)
                let target = request.split(separator: " ").dropFirst().first == "/target"
                counts.withLock { if target { $0.target += 1 } else { $0.source += 1 } }
                let body = target ? Data("redirect target reached".utf8) : Self.body
                let status = target ? "200 OK" : "307 Temporary Redirect"
                let location = target ? "" : "Location: \(targetURL.absoluteString)\r\n"
                var response = Data("HTTP/1.1 \(status)\r\n\(location)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                response.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = send(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, Int32(MSG_NOSIGNAL))
                        guard written > 0 else { break }
                        offset += written
                    }
                }
            }
            Glibc.close(client)
        }
    }
    private enum FixtureFailure: Error { case socket }
}
#endif
