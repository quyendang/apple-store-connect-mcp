import Foundation
import MCP

private struct FixedCloudSessionID: SessionIDGenerator {
    let id: String
    func generateSessionID() -> String { id }
}

/// Owns native in-process MCP servers, isolated accounts, file transfer and background execution.
actor CloudRuntime {
    struct Session: Sendable {
        let id: String
        let owner: String
        let server: Server
        let transport: StatefulHTTPServerTransport
        let manager: WorkerManager
        var lastUsed: Date
    }
    private let configuration: CloudConfiguration
    private let options: AppRuntimeOptions
    let files: CloudFiles
    let jobs: CloudJobs
    private var sessions: [String: Session] = [:]
    private var initializing = 0

    /// Initialize persistent cloud services without creating shared company-switch state.
    /// - Returns: A runtime that creates an independent WorkerManager per MCP session.
    /// - Throws: Persistent-state read/write errors.
    init(configuration: CloudConfiguration, options: AppRuntimeOptions) throws {
        self.configuration = configuration
        self.options = options
        files = try CloudFiles(configuration: configuration)
        jobs = try CloudJobs(directory: configuration.dataDirectory)
    }

    /// Create a native SDK transport and register every original worker tool plus cloud additions.
    /// - Returns: A grant-bound MCP session using direct Swift calls.
    /// - Throws: Capacity, credential initialization or SDK errors.
    func createSession(principal: CloudPrincipal) async throws -> Session {
        await expireSessions()
        guard sessions.count + initializing < configuration.maximumSessions else { throw CloudFailure(status: 429, message: "Too many active MCP sessions") }
        initializing += 1
        defer { initializing -= 1 }
        let id = UUID().uuidString
        let companies = try CompaniesManager(config: configuration.companies, configSource: "cloud configuration")
        let manager = try await WorkerManager.createForProduction(companiesWorker: CompaniesWorker(manager: companies), enabledWorkers: options.enabledWorkers, readOnlyMode: options.readOnlyMode || !principal.canWrite)
        let server = Server(name: "apple-store-connect-mcp", version: ServerVersion.current,
            instructions: "All original App Store Connect tools are available. Each HTTP session has its own company selection. Upload local assets with bridge_files_create_upload first, then pass file_id or the returned file_path. Run long operations with bridge_jobs_submit and inspect bridge_jobs_get. Preserve exact destructive confirmations. context_id can refer to another active session owned by this OAuth connection. Never retry uncertain Apple writes without inspection.",
            capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in
            let original = await manager.collectWorkerToolSnapshots().flatMap(\.tools).map(ToolMetadataPolicy.apply).map(CloudTools.cloudDefinition)
            return ListTools.Result(tools: original + CloudTools.definitions())
        }
        await server.withMethodHandler(CallTool.self) { params in
            do { return try await self.call(params, principal: principal, defaultContextID: id) }
            catch let failure as CloudFailure { return MCPResult.error(failure.message) }
            catch { return MCPResult.error(error) }
        }
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedCloudSessionID(id: id), validationPipeline: StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(), ProtocolVersionValidator(), SessionValidator()
        ]), retryInterval: 1000)
        try await server.start(transport: transport)
        let session = Session(id: id, owner: principal.grantID, server: server, transport: transport, manager: manager, lastUsed: Date())
        sessions[id] = session
        return session
    }

    /// Return a stable catalog independent of HTTP connections.
    /// - Returns: Every enabled original tool plus cloud tools in deterministic order.
    /// - Throws: Tool catalog construction errors.
    func catalog() async throws -> [Tool] {
        let snapshots = try await ASCToolCatalogFactory.collectWorkerToolSnapshots()
        let enabled = snapshots.filter { snapshot in
            guard let keys = options.enabledWorkers else { return true }
            return ["company", "auth"].contains(snapshot.key) || keys.contains(snapshot.key)
                || (keys.contains("builds") && ["build_beta", "build_processing"].contains(snapshot.key))
        }
        return (enabled.flatMap(\.tools).map(ToolMetadataPolicy.apply).map(CloudTools.cloudDefinition) + CloudTools.definitions()).sorted { $0.name < $1.name }
    }

    /// Resolve a session only for the authenticated OAuth grant.
    /// - Returns: The isolated native server context.
    /// - Throws: CloudFailure with 404 for unknown or expired sessions.
    func session(id: String, principal: CloudPrincipal) throws -> Session {
        guard var session = sessions[id], session.owner == principal.grantID else { throw CloudFailure(status: 404, message: "Unknown MCP session; initialize a new session") }
        session.lastUsed = Date(); sessions[id] = session
        return session
    }

    /// End a session without cancelling or replaying durable background jobs.
    /// - Returns: Nothing.
    /// - Throws: Never.
    func removeSession(id: String) async {
        if let session = sessions.removeValue(forKey: id) { await session.server.stop() }
    }

    /// Dispatch additive cloud tools or invoke the existing WorkerManager directly.
    /// - Returns: Original MCP results or cloud file/job receipts.
    /// - Throws: Authorization, context, file validation or persistence errors.
    func call(_ params: CallTool.Parameters, principal: CloudPrincipal, defaultContextID: String) async throws -> CallTool.Result {
        var arguments = params.arguments ?? [:]
        let contextValue = arguments.removeValue(forKey: "context_id")
        guard contextValue == nil || contextValue?.stringValue != nil else { throw CloudFailure(status: 400, message: "context_id must be a string") }
        let contextID = contextValue?.stringValue ?? defaultContextID
        let context = try session(id: contextID, principal: principal)
        switch params.name {
        case "bridge_context_create":
            guard arguments.isEmpty else { throw CloudFailure(status: 400, message: "Unexpected arguments") }
            let created = try await createSession(principal: principal)
            return MCPResult.jsonObject(["context_id": created.id])
        case "bridge_files_create_upload":
            guard Set(arguments.keys) == ["file_name"], let name = arguments["file_name"]?.stringValue else { throw CloudFailure(status: 400, message: "Required file_name") }
            return try await files.createUpload(name: name, owner: principal.grantID)
        case "bridge_files_list":
            guard arguments.isEmpty else { throw CloudFailure(status: 400, message: "Unexpected arguments") }
            return await files.list(owner: principal.grantID)
        case "bridge_jobs_get":
            guard Set(arguments.keys) == ["job_id"], let id = arguments["job_id"]?.stringValue else { throw CloudFailure(status: 400, message: "Required job_id") }
            return try await jobs.get(id: id, owner: principal.grantID)
        case "bridge_jobs_submit":
            guard Set(arguments.keys).isSubset(of: ["tool_name", "arguments", "operation_id"]),
                  let name = arguments["tool_name"]?.stringValue, let operation = arguments["operation_id"]?.stringValue,
                  case .object(let original) = arguments["arguments"], !name.hasPrefix("bridge_"), !name.hasPrefix("auth_"), name != "company_switch" else { throw CloudFailure(status: 400, message: "Required original tool_name, arguments and operation_id; auth/company-switch tools run synchronously") }
            try authorizeTool(name, principal: principal)
            let resolved = try await files.arguments(original, owner: principal.grantID)
            let selectedCompany = try await context.manager.companyForHTTPJob()
            let fixedCompanies = try CompaniesManager(config: CompaniesConfig(companies: [selectedCompany]), configSource: "background job account snapshot")
            let fixedManager = try await WorkerManager.createForProduction(companiesWorker: CompaniesWorker(manager: fixedCompanies), enabledWorkers: options.enabledWorkers, readOnlyMode: options.readOnlyMode || !principal.canWrite)
            return try await jobs.submit(owner: principal.grantID, operationID: operation, contextID: contextID, manager: fixedManager, params: CallTool.Parameters(name: name, arguments: resolved, meta: params._meta))
        default:
            try authorizeTool(params.name, principal: principal)
            let resolved = try await files.arguments(arguments, owner: principal.grantID)
            return try await context.manager.callFromHTTP(.init(name: params.name, arguments: resolved, meta: params._meta))
        }
    }

    private func authorizeTool(_ name: String, principal: CloudPrincipal) throws {
        if name.hasPrefix("auth_"), !principal.canAdmin { throw CloudFailure(status: 403, message: "asc:admin permission required") }
        if name != "company_switch", !ToolMetadataPolicy.isReadOnly(name), (!principal.canWrite || options.readOnlyMode) { throw CloudFailure(status: 403, message: "Write operations are disabled or asc:write permission is missing") }
        if !principal.scopes.contains("asc:read") { throw CloudFailure(status: 403, message: "asc:read permission required") }
    }
    private func expireSessions() async {
        let expired = sessions.values.filter { Date().timeIntervalSince($0.lastUsed) > 3600 }.map(\.id)
        for id in expired { await removeSession(id: id) }
    }
}
