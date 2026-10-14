import Foundation
import MCP

/// Cloud-only additions; every original tool remains registered unchanged apart from optional file references.
enum CloudTools {
    static let names: Set<String> = ["bridge_context_create", "bridge_files_create_upload", "bridge_files_list", "bridge_jobs_submit", "bridge_jobs_get"]

    /// Build definitions for file transfer and durable background execution.
    /// - Returns: Five additive MCP tool definitions with explicit safety annotations.
    /// - Throws: Never.
    static func definitions() -> [Tool] {
        let string: Value = .object(["type": .string("string")])
        return [
            tool("bridge_context_create", "Create an isolated company-selection context. Handshake-free clients pass returned context_id to later calls.", properties: [:], required: [], readOnly: false),
            tool("bridge_files_create_upload", "Create a single-use browser upload link. Upload the file, then use file_id or the returned file_path with existing upload tools.", properties: ["file_name": string], required: ["file_name"], readOnly: false),
            tool("bridge_files_list", "List uploaded assets owned by this OAuth connection, with file IDs, paths and sizes.", properties: [:], required: [], readOnly: true),
            tool("bridge_jobs_submit", "Run an existing tool as a durable background job. Requires the original tool's exact inputs and confirmations. May create, update, release or delete resources. Never retry after an unknown outcome without inspection. Use bridge_jobs_get for the original result.", properties: ["tool_name": string, "arguments": .object(["type": .string("object"), "additionalProperties": .bool(true)]), "context_id": string, "operation_id": string], required: ["tool_name", "arguments", "operation_id"], readOnly: false),
            tool("bridge_jobs_get", "Read a background job's status and complete original MCP result. A restart leaves unfinished writes unknown and requiring inspection.", properties: ["job_id": string], required: ["job_id"], readOnly: true)
        ]
    }
    private static func tool(_ name: String, _ description: String, properties: [String: Value], required: [String], readOnly: Bool) -> Tool {
        Tool(name: name, description: description, inputSchema: .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)]), annotations: .init(readOnlyHint: readOnly, destructiveHint: !readOnly, idempotentHint: readOnly, openWorldHint: true))
    }

    /// Add optional file IDs without dropping legacy file_path requirements for local clients.
    /// - Returns: Cloud schema accepting either a registered path or a cloud file reference.
    /// - Throws: Never.
    static func cloudDefinition(_ original: Tool) -> Tool {
        guard case .object(var schema) = original.inputSchema, case .object(var properties) = schema["properties"] else { return original }
        var alternatives: [Value] = []
        var required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        for (path, id) in [("file_path", "file_id"), ("file_paths", "file_ids")] where properties[path] != nil {
            properties[id] = path == "file_path" ? .object(["type": .string("string"), "description": .string("ID returned by the cloud upload portal")]) : .object(["type": .string("array"), "items": .object(["type": .string("string")])])
            if required.contains(path) {
                required.removeAll { $0 == path }
                alternatives.append(.object(["anyOf": .array([.object(["required": .array([.string(path)])]), .object(["required": .array([.string(id)])])])]))
            }
        }
        properties["context_id"] = .object(["type": .string("string"), "description": .string("Optional cloud working context; omit to use this HTTP session's isolated context")])
        schema["properties"] = .object(properties)
        schema["required"] = .array(required.map(Value.string))
        if !alternatives.isEmpty { schema["allOf"] = .array((schema["allOf"]?.arrayValue ?? []) + alternatives) }
        return Tool(name: original.name, title: original.title, description: original.description, inputSchema: .object(schema), annotations: original.annotations, outputSchema: original.outputSchema, icons: original.icons, _meta: original._meta)
    }
}
