import Foundation
import Hummingbird
import HTTPTypes
import MCP

/// Handshake-free tool binding; legacy HTTP uses the official SDK transport.
/// Business state is an explicit owner-bound context, independent of HTTP connections.
enum CloudModernRPC {
    static let version = "2026-07-28"

    /// Validate per-request metadata and dispatch the advertised tools capability.
    /// - Returns: JSON-RPC with modern resultType and no transport session header.
    /// - Throws: Encoding or cloud service errors.
    static func handle(input: Data, request: Hummingbird.Request, runtime: CloudRuntime, principal: CloudPrincipal) async throws -> Response {
        let value: Value
        do { value = try JSONDecoder().decode(Value.self, from: input) }
        catch { return error(id: .null, code: -32700, message: "Invalid JSON", status: 400) }
        guard case .object(let envelope) = value, envelope["jsonrpc"]?.stringValue == "2.0", let method = envelope["method"]?.stringValue,
              let id = envelope["id"], validID(id), case .object(let params) = envelope["params"], case .object(let meta) = params["_meta"],
              let requested = meta["io.modelcontextprotocol/protocolVersion"]?.stringValue else {
            return error(id: value.objectValue?["id"] ?? .null, code: -32600, message: "Required JSON-RPC ID and per-request _meta", status: 400)
        }
        guard requested == version else {
            return raw(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(-32022), "message": .string("Unsupported protocol version"), "data": .object(["supported": .array(supported), "requested": .string(requested)])])]), status: 400)
        }
        guard request.headers[HTTPField.Name("MCP-Protocol-Version")!] == requested, request.headers[HTTPField.Name("Mcp-Method")!] == method,
              case .object(let info) = meta["io.modelcontextprotocol/clientInfo"], info["name"]?.stringValue != nil, info["version"]?.stringValue != nil,
              case .object = meta["io.modelcontextprotocol/clientCapabilities"], request.headers[.contentType]?.lowercased().hasPrefix("application/json") == true,
              request.headers[.accept]?.contains("application/json") == true, request.headers[.accept]?.contains("text/event-stream") == true else {
            return error(id: id, code: -32600, message: "Missing or mismatched request headers and metadata", status: 400)
        }
        do {
            switch method {
            case "server/discover":
                return raw(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object([
                    "resultType": .string("complete"), "supportedVersions": .array(supported), "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                    "_meta": .object(["io.modelcontextprotocol/serverInfo": .object(["name": .string("apple-store-connect-mcp"), "version": .string(ServerVersion.current)])]),
                    "instructions": .string("Call bridge_context_create, then pass context_id to all tool calls. Each context has an isolated selected company. Upload files with bridge_files_create_upload. Long operations use bridge_jobs_submit. All original tools are preserved. Contexts expire after one hour of inactivity or restart; files, OAuth grants and job receipts persist."),
                    "ttlMs": .int(60000), "cacheScope": .string("private")])]))
            case "tools/list":
                guard params["cursor"] == nil else { return error(id: id, code: -32602, message: "Catalog is returned without cursors", status: 400) }
                let tools = try await runtime.catalog()
                var result = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(ListTools.Result(tools: tools))).objectValue ?? [:]
                result["resultType"] = .string("complete"); result["ttlMs"] = .int(60000); result["cacheScope"] = .string("private")
                return raw(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(result)]))
            case "tools/call":
                guard let name = params["name"]?.stringValue, request.headers[HTTPField.Name("Mcp-Name")!] == name,
                      params["arguments"] == nil || params["arguments"]?.objectValue != nil else { return error(id: id, code: -32602, message: "Mcp-Name must match params.name; arguments must be an object", status: 400) }
                let arguments = params["arguments"]?.objectValue ?? [:]
                let result: CallTool.Result
                if name == "bridge_context_create" {
                    guard arguments.isEmpty else { return error(id: id, code: -32602, message: "No arguments expected", status: 400) }
                    let context = try await runtime.createSession(principal: principal)
                    result = MCPResult.jsonObject(["context_id": context.id])
                } else {
                    guard let context = arguments["context_id"]?.stringValue, !context.isEmpty else { return complete(id: id, result: MCPResult.error("Call bridge_context_create first, then pass context_id with every tool call")) }
                    result = try await runtime.call(.init(name: name, arguments: arguments, meta: Metadata(additionalFields: meta)), principal: principal, defaultContextID: context)
                }
                return complete(id: id, result: result)
            default:
                return error(id: id, code: -32601, message: "Unknown method", status: 404)
            }
        } catch let failure as CloudFailure { return complete(id: id, result: MCPResult.error(failure.message)) }
        catch { return complete(id: id, result: MCPResult.error(error)) }
    }
    private static var supported: [Value] { ([version] + Array(Version.supported.sorted().reversed())).map(Value.string) }
    private static func complete(id: Value, result: CallTool.Result) -> Response {
        guard let data = try? JSONEncoder().encode(result), let value = try? JSONDecoder().decode(Value.self, from: data), var object = value.objectValue else { return error(id: id, code: -32603, message: "Unable to encode result", status: 500) }
        object["resultType"] = .string("complete")
        return raw(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object(object)]))
    }
    private static func error(id: Value, code: Int, message: String, status: Int) -> Response {
        raw(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(code), "message": .string(message)])]), status: status)
    }
    private static func raw(_ value: Value, status: Int = 200) -> Response {
        Response(status: .init(code: status), headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))))
    }
    private static func validID(_ value: Value) -> Bool { switch value { case .string, .int: return true; default: return false } }
}
