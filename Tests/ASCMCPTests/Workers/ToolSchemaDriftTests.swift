import Foundation
import MCP
import Testing
@testable import asc_mcp

@Suite("Tool Schema Drift Tests")
struct ToolSchemaDriftTests {
    @Test("app version states include current Apple OpenAPI values")
    func appVersionStatesIncludeCurrentAppleValues() async throws {
        let worker = AppLifecycleWorker(httpClient: try await TestFactory.makeHTTPClient())
        let tool = try #require(await worker.getTools().first { $0.name == "app_versions_list" })
        let states = try enumValues(in: tool, path: ["states", "items"])

        #expect(states.contains("ACCEPTED"))
        #expect(states.contains("NOT_APPLICABLE"))
    }

    @Test("external beta state includes current Apple OpenAPI values")
    func externalBetaStateIncludesCurrentAppleValues() async throws {
        let worker = BuildBetaDetailsWorker(httpClient: try await TestFactory.makeHTTPClient())
        let tool = try #require(await worker.getTools().first { $0.name == "builds_update_beta_detail" })
        let states = try enumValues(in: tool, path: ["external_build_state"])

        #expect(states.contains("WAITING_FOR_BETA_REVIEW"))
        #expect(states.contains("NOT_APPLICABLE"))
    }
}

private func enumValues(in tool: Tool, path: [String]) throws -> Set<String> {
    guard case .object(let root) = tool.inputSchema,
          case .object(let properties)? = root["properties"] else {
        throw ToolSchemaDriftTestError.missingProperties(tool.name)
    }

    var current: Value? = .object(properties)
    for segment in path {
        guard case .object(let object)? = current else {
            throw ToolSchemaDriftTestError.missingPath(path.joined(separator: "."))
        }
        current = object[segment]
    }

    guard case .object(let target)? = current,
          case .array(let values)? = target["enum"] else {
        throw ToolSchemaDriftTestError.missingEnum(path.joined(separator: "."))
    }

    return Set(values.compactMap(\.stringValue))
}

private enum ToolSchemaDriftTestError: Error {
    case missingProperties(String)
    case missingPath(String)
    case missingEnum(String)
}
