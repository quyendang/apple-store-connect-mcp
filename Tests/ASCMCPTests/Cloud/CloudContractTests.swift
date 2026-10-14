import Foundation
import Testing
import MCP
@testable import asc_mcp

@Suite("Native HTTP Cloud Contracts")
struct CloudContractTests {
    private func configuration(directory: URL) throws -> CloudConfiguration {
        let config = CompaniesConfig(companies: [TestFactory.makeCompany()])
        return try CloudConfiguration(environment: [
            "MCP_PUBLIC_URL": "http://localhost:8080", "MCP_ADMIN_PASSWORD": "test-owner-password-with-enough-entropy",
            "MCP_DATA_DIR": directory.path, "ASC_COMPANIES_JSON": String(decoding: JSONEncoder().encode(config), as: UTF8.self)
        ])
    }

    @Test("Full cloud catalog keeps all 502 original names and path alternatives")
    func catalogParity() async throws {
        let original = try await TestFactory.collectAllWorkerTools().map(ToolMetadataPolicy.apply)
        let cloud = original.map(CloudTools.cloudDefinition)
        #expect(original.count == 502)
        #expect(original.map(\.name) == cloud.map(\.name))
        for (before, after) in zip(original, cloud) {
            #expect(before.description == after.description)
            #expect(before.outputSchema == after.outputSchema)
            #expect(before.annotations == after.annotations)
        }
        let upload = try #require(cloud.first { $0.name == "screenshots_upload" })
        #expect(upload.inputSchema.objectValue?["properties"]?.objectValue?["file_id"] != nil)
        #expect(upload.inputSchema.objectValue?["allOf"]?.arrayValue?.isEmpty == false)
    }

    @Test("Cloud refuses public HTTP, weak credentials and non-Apple credential destinations")
    func configurationRejectsUnsafeValues() throws {
        #expect(throws: ASCError.self) { try CloudConfiguration(environment: ["MCP_PUBLIC_URL": "http://example.com"]) }
        #expect(throws: ASCError.self) { try CloudConfiguration(environment: ["MCP_PUBLIC_URL": "https://example.com", "MCP_ADMIN_PASSWORD": "short"]) }
        let config = CompaniesConfig(companies: [TestFactory.makeCompany()], defaultURL: "https://attacker.example")
        #expect(throws: ASCError.self) { try CloudConfiguration(environment: ["MCP_PUBLIC_URL": "https://example.com", "MCP_ADMIN_PASSWORD": "test-owner-password-with-enough-entropy", "ASC_COMPANIES_JSON": String(decoding: JSONEncoder().encode(config), as: UTF8.self)]) }
    }

    @Test("Reject duplicate authorization fields and escape portal markup")
    func inputAmbiguity() throws {
        #expect(throws: CloudFailure.self) { try CloudSecurity.form("client_id=a&client_id=b") }
        #expect(try CloudSecurity.form("password=a%2Bb+c")["password"] == "a+b c")
        #expect(CloudSecurity.html("<script>\"&") == "&lt;script&gt;&quot;&amp;")
        #expect(!CloudSecurity.equal("wrong", "right"))
        #expect(CloudSecurity.equal("right", "right"))
    }

    @Test("Owner-scoped sessions cannot be used by another grant")
    func grantIsolation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try configuration(directory: dir)
        let runtime = try CloudRuntime(configuration: config, options: .init())
        let alice = CloudPrincipal(grantID: "alice", scopes: ["asc:read", "asc:write", "asc:admin"])
        let bob = CloudPrincipal(grantID: "bob", scopes: ["asc:read", "asc:write", "asc:admin"])
        let session = try await runtime.createSession(principal: alice)
        await #expect(throws: CloudFailure.self) { try await runtime.session(id: session.id, principal: bob) }
        await runtime.removeSession(id: session.id)
    }

    @Test("Cloud files cannot reference secrets, unowned paths or traversal filenames")
    func fileConfinement() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try CloudFiles(configuration: configuration(directory: dir))
        await #expect(throws: CloudFailure.self) { try await files.arguments(["file_path": .string("/etc/passwd")], owner: "owner") }
        await #expect(throws: CloudFailure.self) { try await files.arguments(["files": .array([.object(["file_path": .string("/run/secrets/apple.p8")])])], owner: "owner") }
        await #expect(throws: CloudFailure.self) { try await files.createUpload(name: "../private.p8", owner: "owner") }
        await #expect(throws: CloudFailure.self) { try await files.arguments(["file_id": .string("unknown")], owner: "owner") }
    }
}

@Suite("Cloud Job Recovery Contract")
struct CloudJobRecoveryContractTests {
    @Test("A failed Apple write with unknown outcome preserves the inspection requirement")
    func unknownWriteRequiresInspection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = MCPResult.error(ASCError.mutationOutcomeUnknown(method: "POST", cause: .network("connection interrupted")))
        let job = CloudJobs.Job(id: "job", owner: "owner", operationID: "operation", requestHash: "hash", toolName: "iap_create", contextID: "context", createdAt: Date(), status: "failed", result: result)
        try JSONEncoder().encode(["job": job]).write(to: directory.appendingPathComponent("jobs.json"))
        let service = try CloudJobs(directory: directory)
        let receipt = try await service.get(id: "job", owner: "owner")
        #expect(receipt.structuredContent?.objectValue?["inspection_required"] == .bool(true))
        #expect(receipt.structuredContent?.objectValue?["retry_safe"] == .bool(false))
        #expect(receipt.structuredContent?.objectValue?["original_result"]?.objectValue?["structuredContent"]?.objectValue?["operationCommitState"] == .string("unknown"))
    }
}
