import Foundation
import MCP

/// Persist background operation receipts without automatically replaying ambiguous Apple writes.
actor CloudJobs {
    struct Job: Codable, Sendable {
        let id: String
        let owner: String
        let operationID: String
        let requestHash: String
        let toolName: String
        let contextID: String
        let createdAt: Date
        var status: String
        var result: CallTool.Result?
    }
    private let stateURL: URL
    private var jobs: [String: Job]
    private var activeCount = 0

    /// Load durable receipts; mark in-flight jobs unknown after an interrupted deployment.
    /// - Returns: A bounded background job service.
    /// - Throws: Storage or decoding errors.
    init(directory: URL) throws {
        stateURL = directory.appendingPathComponent("jobs.json")
        var loaded = FileManager.default.fileExists(atPath: stateURL.path) ? try JSONDecoder().decode([String: Job].self, from: Data(contentsOf: stateURL)) : [:]
        for id in loaded.keys where loaded[id]!.status == "running" { loaded[id]!.status = "unknown" }
        jobs = loaded
        try JSONEncoder().encode(loaded).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    /// Submit a deduplicated original tool call, preserving its complete result.
    /// - Returns: A durable job receipt or an existing receipt for the same operation ID and input.
    /// - Throws: CloudFailure for collisions/limits, or persistence errors before execution starts.
    func submit(owner: String, operationID: String, contextID: String, manager: WorkerManager, params: CallTool.Parameters) throws -> CallTool.Result {
        guard !operationID.isEmpty, operationID.utf8.count <= 128 else { throw CloudFailure(status: 400, message: "operation_id must be a stable non-empty identifier of at most 128 bytes") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = CloudSecurity.hash(contextID + String(decoding: try encoder.encode(params), as: UTF8.self))
        if let existing = jobs.values.first(where: { $0.owner == owner && $0.operationID == operationID }) {
            guard existing.requestHash == hash else { throw CloudFailure(status: 409, message: "operation_id already belongs to different inputs or context") }
            return receipt(existing)
        }
        guard activeCount < 4, jobs.count < 10000 else { throw CloudFailure(status: 429, message: "Background job capacity reached") }
        let id = UUID().uuidString
        let job = Job(id: id, owner: owner, operationID: operationID, requestHash: hash, toolName: params.name, contextID: contextID, createdAt: Date(), status: "running", result: nil)
        jobs[id] = job
        do { try persist() } catch { jobs.removeValue(forKey: id); throw error }
        activeCount += 1
        Task {
            let result: CallTool.Result
            do { result = try await manager.callFromHTTP(params) }
            catch { result = MCPResult.error(error) }
            self.complete(id: id, result: result)
        }
        return receipt(job)
    }

    /// Retrieve a receipt and the complete original MCP result for its owner.
    /// - Returns: Job status, inspection requirements and optional original result.
    /// - Throws: CloudFailure for unknown/cross-owner job IDs.
    func get(id: String, owner: String) throws -> CallTool.Result {
        guard let job = jobs[id], job.owner == owner else { throw CloudFailure(status: 404, message: "Unknown job") }
        return receipt(job)
    }

    private func complete(id: String, result: CallTool.Result) {
        guard var job = jobs[id] else { return }
        job.result = result
        job.status = result.isError == true ? "failed" : "completed"
        jobs[id] = job
        activeCount -= 1
        do { try persist() }
        catch { print("Cloud job receipt could not be persisted; inspect Apple before retrying after a restart", to: &standardError) }
    }
    private func receipt(_ job: Job) -> CallTool.Result {
        let originalFields = job.result?.structuredContent?.objectValue ?? [:]
        let commitState = originalFields["operationCommitState"]?.stringValue
        let inspectionRequired = job.status == "unknown" || originalFields["inspectionRequired"]?.boolValue == true
            || commitState == "unknown" || commitState == "committed_unverified"
        var object: [String: Any] = ["job_id": job.id, "operation_id": job.operationID, "tool_name": job.toolName, "context_id": job.contextID, "status": job.status, "created_at": ISO8601DateFormatter().string(from: job.createdAt), "inspection_required": inspectionRequired, "retry_safe": false]
        if let result = job.result, let encoded = try? JSONEncoder().encode(result), let value = try? JSONSerialization.jsonObject(with: encoded) { object["original_result"] = value }
        if job.status == "unknown" { object["recovery"] = "The server restarted during this operation. Inspect the original resource using the matching read tool before submitting a new operation. Do not blindly replay this write." }
        return MCPResult.jsonObject(object)
    }
    private func persist() throws {
        try JSONEncoder().encode(jobs).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}
