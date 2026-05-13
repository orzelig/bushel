import Foundation

// MARK: - VMMetadata

/// User-editable per-VM metadata that lives alongside the VM's other files
/// in the VM directory. Surfaced in the dashboard, the HTTP API
/// (`GET /lume/vms`, `GET /lume/vms/:name`, `GET/PUT /lume/vms/:name/metadata`),
/// and the MCP envelope. All fields are optional so VMs created before this
/// feature existed (i.e. with no sidecar file) keep working unchanged.
///
/// Persisted as a sidecar JSON file `bushel-metadata.json` in the VM's
/// directory. The `bushel-` prefix is intentional: it signals that this is
/// bushel-specific data (not part of the upstream lume layout), and is
/// harmless leftover if a user ever swaps bushel back for stock lume.
struct VMMetadata: Codable, Sendable, Equatable {
    var creator: String?
    var description: String?
    var owner: String?
    /// ISO8601 timestamp of the last write. Server-set on every write — any
    /// client-supplied value is discarded so the timestamp is always reliable.
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case creator
        case description
        case owner
        case updatedAt = "updated_at"
    }

    init(
        creator: String? = nil,
        description: String? = nil,
        owner: String? = nil,
        updatedAt: String? = nil
    ) {
        self.creator = creator
        self.description = description
        self.owner = owner
        self.updatedAt = updatedAt
    }

    /// `true` when none of the user-editable fields carry a value. Used to
    /// decide whether to encode the sidecar inline in VMDetails as `{}` or
    /// just leave the structure empty — the rendering side handles either,
    /// but the empty-everything case is the common one for fresh VMs.
    var isEmpty: Bool {
        creator == nil && description == nil && owner == nil && updatedAt == nil
    }

    /// Returns an ISO8601 timestamp for "now" using the fractional-seconds
    /// formatter, matching what other date-stamped sidecars in the codebase
    /// would produce. Centralized here so the storage layer and the round-trip
    /// test agree on format.
    static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

// MARK: - VMMetadataStore

/// Reads and writes the per-VM metadata sidecar.
///
/// Lookup goes through `Home.getVMDirectory(name:storage:)` so multi-storage
/// setups (and direct-path storage) work the same way as the rest of bushel's
/// VM-directory addressing.
///
/// Reads are forgiving: a missing sidecar returns an empty `VMMetadata`, not
/// an error. The dashboard and the API embed an empty object in that case,
/// which is what every VM that pre-dates this feature will look like.
///
/// Writes are atomic: encoded JSON is dropped into `bushel-metadata.json.tmp`
/// in the same directory and then `rename(2)`d over the final filename.
/// `rename` on the same filesystem is atomic, so a reader will always see
/// either the old file or the new — never a half-written one.
struct VMMetadataStore {
    private static let fileName = "bushel-metadata.json"

    /// The Home instance used to resolve VM directories. Defaults to a fresh
    /// one; tests can pass in their own to point at a temporary location.
    let home: Home

    init(home: Home) {
        self.home = home
    }

    /// Resolves the sidecar path for a VM. Used by both `load` and `save` and
    /// exposed so tests can poke at the file on disk directly.
    func sidecarPath(for name: String, storage: String? = nil) throws -> Path {
        let vmDir = try home.getVMDirectory(name, storage: storage)
        return vmDir.dir.file(Self.fileName)
    }

    /// Reads the sidecar from disk. Returns an empty `VMMetadata` if the file
    /// doesn't exist or can't be decoded. We intentionally don't throw on
    /// missing-file: a brand-new VM never has metadata, and surfacing a "file
    /// not found" error here would force every caller (HTTP handlers, the
    /// lightweight VMDetails builder) to wrap the call in `try?`. Decode
    /// failures are also swallowed (returns empty) — the alternative is the
    /// dashboard rendering nothing because a hand-edited JSON typo nuked the
    /// whole row, which is worse than the user just re-saving from the edit
    /// dialog.
    func load(name: String, storage: String? = nil) -> VMMetadata {
        guard let path = try? sidecarPath(for: name, storage: storage) else {
            return VMMetadata()
        }
        return Self.loadFromPath(path)
    }

    /// Lower-level variant used by `getDetails`-style callers that already
    /// have a resolved `VMDirectory` and don't want to re-resolve via Home.
    static func load(from vmDir: VMDirectory) -> VMMetadata {
        return loadFromPath(vmDir.dir.file(fileName))
    }

    private static func loadFromPath(_ path: Path) -> VMMetadata {
        guard let data = try? Data(contentsOf: path.url) else {
            return VMMetadata()
        }
        do {
            return try JSONDecoder().decode(VMMetadata.self, from: data)
        } catch {
            // Don't surface a malformed-sidecar error: the dashboard is
            // far more useful with a blank metadata block than blank
            // everything. Logging once at info level so a power user
            // can spot the corruption in `bushel logs`.
            Logger.info(
                "Failed to decode VM metadata sidecar; treating as empty",
                metadata: ["path": path.path, "error": error.localizedDescription])
            return VMMetadata()
        }
    }

    /// Atomically writes metadata. Stamps `updated_at` server-side, ignoring
    /// any value the caller put there. Returns the metadata as actually
    /// written (i.e. with the server-set timestamp) so handlers can echo it
    /// back without re-reading.
    @discardableResult
    func save(_ metadata: VMMetadata, name: String, storage: String? = nil) throws -> VMMetadata {
        // Resolve the VM directory. This intentionally does NOT verify the VM
        // exists — that's the handler's job (so it can return a clean 404
        // instead of a cryptic file-not-found from FileManager).
        let vmDir = try home.getVMDirectory(name, storage: storage)

        // Make sure the directory exists. For a VM that the caller has
        // already validated exists, this is a no-op. For tests, it lets us
        // skip a separate `createDirectory` call.
        if !vmDir.dir.exists() {
            try FileManager.default.createDirectory(
                at: vmDir.dir.url, withIntermediateDirectories: true)
        }

        // Stamp updated_at unconditionally. The user could send us any value
        // (or nothing) and we'd still want a reliable timestamp on disk.
        var stamped = metadata
        stamped.updatedAt = VMMetadata.currentTimestamp()

        let finalPath = vmDir.dir.file(Self.fileName)
        let tempPath = vmDir.dir.file(Self.fileName + ".tmp")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stamped)

        // Two-step atomic write: write the temp file, then rename over the
        // final filename. POSIX rename(2) on the same filesystem is atomic;
        // readers see either the pre-write file or the post-write file but
        // never a partial write. We use `Data.write(to:options:.atomic)`
        // for the temp file itself (also rename-based on Apple platforms),
        // and then explicitly move the temp file into place — letting us
        // control the final name and survive an interrupted process at the
        // rename boundary rather than the write boundary.
        try data.write(to: tempPath.url, options: .atomic)

        // If a previous write got interrupted between the temp-file write and
        // the rename, the final file may or may not exist. POSIX rename
        // handles both cases (replaces if present, creates if not).
        let fm = FileManager.default
        if fm.fileExists(atPath: finalPath.path) {
            // FileManager.replaceItemAt uses an atomic backed-by-rename
            // strategy on Apple platforms when both files are on the same
            // volume. Pass nil for the backup item URL — we don't need a
            // versioned backup of the previous metadata.
            _ = try fm.replaceItemAt(finalPath.url, withItemAt: tempPath.url)
        } else {
            try fm.moveItem(at: tempPath.url, to: finalPath.url)
        }

        return stamped
    }
}
