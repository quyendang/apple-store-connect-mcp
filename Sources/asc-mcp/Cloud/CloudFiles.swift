import Foundation
import Hummingbird
import MCP

/// Durable asset storage with expiring upload links and grant-bound file references.
actor CloudFiles {
    struct Asset: Codable, Sendable {
        let id: String
        let owner: String
        let name: String
        let size: Int
        let createdAt: Date
    }
    struct Ticket: Sendable {
        let owner: String
        let name: String
        let expires: Date
    }
    private let root: URL
    private let stateURL: URL
    private let configuration: CloudConfiguration
    private var assets: [String: Asset]
    private var tickets: [String: Ticket] = [:]
    private var activeUploads: Set<String> = []

    /// Load the persistent asset catalog and create a private storage directory.
    /// - Returns: Storage bound to the configured Railway volume.
    /// - Throws: File/decoding errors instead of ignoring a corrupt catalog.
    init(configuration: CloudConfiguration) throws {
        self.configuration = configuration
        root = configuration.dataDirectory.appendingPathComponent("assets", isDirectory: true)
        stateURL = configuration.dataDirectory.appendingPathComponent("assets.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        assets = FileManager.default.fileExists(atPath: stateURL.path) ? try JSONDecoder().decode([String: Asset].self, from: Data(contentsOf: stateURL)) : [:]
    }

    /// Issue a single-use, expiring browser upload URL for an asset.
    /// - Returns: Upload URL, POST endpoint, expiry and maximum accepted size.
    /// - Throws: CloudFailure for invalid filename or exhausted ticket limits.
    func createUpload(name: String, owner: String) throws -> CallTool.Result {
        tickets = tickets.filter { $0.value.expires > Date() }
        guard !name.isEmpty, name.utf8.count <= 200, name == URL(fileURLWithPath: name).lastPathComponent,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              tickets.count < 100 else { throw CloudFailure(status: 400, message: "Invalid filename or too many upload tickets") }
        let raw = CloudSecurity.token()
        tickets[CloudSecurity.hash(raw)] = Ticket(owner: owner, name: name, expires: Date().addingTimeInterval(900))
        return MCPResult.jsonObject(["upload_url": configuration.publicURL + "/upload/" + raw, "upload_endpoint": configuration.publicURL + "/upload/" + raw, "method": "POST", "expires_in": 900, "maximum_bytes": configuration.maximumUploadBytes, "instructions": "Open upload_url, choose the file, upload, then use the returned file_id or file_path with an existing upload tool. For CI POST raw bytes to upload_endpoint."])
    }

    /// Render a browser file uploader without exposing OAuth or Apple credentials.
    /// - Returns: A form using the single-use upload capability.
    /// - Throws: CloudFailure when the ticket has expired.
    func page(ticket raw: String) throws -> String {
        guard let ticket = tickets[CloudSecurity.hash(raw)], ticket.expires > Date() else { throw CloudFailure(status: 404, message: "Upload link expired") }
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Upload asset</title>
        <body style="font:17px system-ui;max-width:640px;margin:64px auto;padding:24px"><h1>Upload \(CloudSecurity.html(ticket.name))</h1>
        <p>The file is stored on your server. Use the returned file ID in your conversation.</p><input id="file" type="file"><button id="upload">Upload</button><pre id="result" style="white-space:pre-wrap"></pre>
        <script>document.getElementById('upload').onclick=async()=>{const f=document.getElementById('file').files[0];if(!f)return;document.getElementById('upload').disabled=true;try{const r=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:f});document.getElementById('result').textContent=JSON.stringify(await r.json(),null,2)}catch(e){document.getElementById('result').textContent=String(e)}};</script></body></html>
        """
    }

    /// Stream a ticket-authorized upload to disk with a hard byte limit and atomic finalization.
    /// - Returns: Stored file ID, server path, size and original filename.
    /// - Throws: CloudFailure for expired tickets/size limits or file/network errors.
    func upload(ticket raw: String, request: Hummingbird.Request) async throws -> Data {
        guard activeUploads.count < 4 else { throw CloudFailure(status: 429, message: "Too many active uploads") }
        guard let ticket = tickets.removeValue(forKey: CloudSecurity.hash(raw)), ticket.expires > Date() else { throw CloudFailure(status: 404, message: "Upload link expired or used") }
        let id = UUID().uuidString
        activeUploads.insert(id)
        defer { activeUploads.remove(id) }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".uploading")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CloudFailure(status: 500, message: "Unable to create upload file") }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            var size = 0
            for try await buffer in request.body {
                let count = buffer.readableBytes
                guard count <= configuration.maximumUploadBytes - size else { throw CloudFailure(status: 413, message: "File exceeds upload limit") }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
                size += count
            }
            guard size > 0 else { throw CloudFailure(status: 400, message: "Empty file") }
            try handle.synchronize(); try handle.close()
            let path = directory.appendingPathComponent(ticket.name)
            try FileManager.default.moveItem(at: temporary, to: path)
            let asset = Asset(id: id, owner: ticket.owner, name: ticket.name, size: size, createdAt: Date())
            assets[id] = asset
            try persist()
            return try JSONSerialization.data(withJSONObject: projection(asset))
        } catch {
            try? handle.close()
            assets.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// List stored assets belonging to the authenticated OAuth grant.
    /// - Returns: Deterministically sorted file metadata and usable server paths.
    /// - Throws: Never.
    func list(owner: String) -> CallTool.Result {
        MCPResult.jsonObject(["files": assets.values.filter { $0.owner == owner }.sorted { $0.createdAt < $1.createdAt }.map(projection)])
    }

    /// Resolve cloud file references and reject paths outside the authenticated asset catalog.
    /// - Returns: Original tool arguments with file_id/file_ids translated into legacy file paths.
    /// - Throws: CloudFailure for unknown files, cross-grant access or arbitrary filesystem paths.
    func arguments(_ arguments: [String: Value], owner: String) throws -> [String: Value] {
        var result = arguments
        if let value = result.removeValue(forKey: "file_id") {
            guard let id = value.stringValue, result["file_path"] == nil else { throw CloudFailure(status: 400, message: "Use either file_id or file_path") }
            result["file_path"] = .string(try resolve(id, owner: owner))
        }
        if let value = result.removeValue(forKey: "file_ids") {
            guard let values = value.arrayValue, result["file_paths"] == nil else { throw CloudFailure(status: 400, message: "Use either file_ids or file_paths") }
            result["file_paths"] = .array(try values.map { guard let id = $0.stringValue else { throw CloudFailure(status: 400, message: "Invalid file ID") }; return .string(try resolve(id, owner: owner)) })
        }
        for (key, value) in result {
            if key == "file_path" {
                guard let path = value.stringValue else { throw CloudFailure(status: 400, message: "Invalid file_path") }
                try validatePath(path, owner: owner)
            } else if key == "file_paths" {
                guard let paths = value.arrayValue else { throw CloudFailure(status: 400, message: "Invalid file_paths") }
                for value in paths { guard let path = value.stringValue else { throw CloudFailure(status: 400, message: "Invalid file_path") }; try validatePath(path, owner: owner) }
            } else if case .object(let object) = value { result[key] = .object(try self.arguments(object, owner: owner)) }
            else if case .array(let array) = value { result[key] = .array(try array.map { if case .object(let object) = $0 { return .object(try self.arguments(object, owner: owner)) }; return $0 }) }
        }
        return result
    }

    private func resolve(_ id: String, owner: String) throws -> String {
        guard let asset = assets[id], asset.owner == owner else { throw CloudFailure(status: 404, message: "Unknown file") }
        let path = assetPath(asset)
        guard path.resolvingSymlinksInPath().path == path.path, FileManager.default.isReadableFile(atPath: path.path) else { throw CloudFailure(status: 404, message: "File unavailable") }
        return path.path
    }
    private func validatePath(_ path: String, owner: String) throws {
        guard let asset = assets.values.first(where: { $0.owner == owner && assetPath($0).path == path }) else { throw CloudFailure(status: 403, message: "Cloud tools accept only registered files owned by this connection; upload first") }
        _ = try resolve(asset.id, owner: owner)
    }
    private func assetPath(_ asset: Asset) -> URL { root.appendingPathComponent(asset.id).appendingPathComponent(asset.name).standardizedFileURL }
    private func projection(_ asset: Asset) -> [String: Any] { ["file_id": asset.id, "file_path": assetPath(asset).path, "file_name": asset.name, "file_size": asset.size, "created_at": ISO8601DateFormatter().string(from: asset.createdAt)] }
    private func persist() throws {
        try JSONEncoder().encode(assets).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}
