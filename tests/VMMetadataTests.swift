import Foundation
import Testing

@testable import bushel

// Tests for the per-VM metadata sidecar feature. Exercises the storage layer
// (VMMetadataStore) directly with a temp Home, plus the GET/PUT HTTP handlers
// via Server.handleGetMetadata / handlePutMetadata. We deliberately don't
// stand up a full NIO bind here — those handlers are isolated functions that
// produce HTTPResponse values, so we can call them straight.

// MARK: - Test helpers

/// Make a temp directory that the caller is responsible for cleaning up.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("bushel-metadata-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Bootstrap a SettingsManager + Home + LumeController triple rooted at the
/// given temp directories. Matches the pattern in LumeControllerTests: point
/// XDG_CONFIG_HOME at a temp dir so the settings file doesn't clobber the
/// user's real config, then create a home pointing at another temp dir.
@MainActor
private func makeTestController(
    configDir: URL,
    homeDir: URL
) throws -> LumeController {
    setenv("XDG_CONFIG_HOME", configDir.path, 1)
    let settingsManager = SettingsManager(fileManager: .default)
    try settingsManager.setHomeDirectory(path: homeDir.path)
    let home = Home(settingsManager: settingsManager, fileManager: .default)
    return LumeController(home: home)
}

/// Build a fully-initialized VM directory at `homeDir/<name>/` with stub
/// disk.img, nvram.bin, and config.json so `validateVMExists` succeeds. The
/// metadata sidecar is intentionally NOT created — that's what the tests
/// either read (empty case) or write (PUT case) themselves.
private func makeInitializedVMDir(in homeDir: URL, name: String) throws -> VMDirectory {
    let vmRoot = homeDir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: vmRoot, withIntermediateDirectories: true)
    let vmDir = VMDirectory(Path(vmRoot.path))

    // Stub disk + nvram. Tiny — we just need the files to exist.
    try Data(repeating: 0, count: 16).write(to: vmDir.diskPath.url)
    try Data(repeating: 0, count: 16).write(to: vmDir.nvramPath.url)

    var config = try VMConfig(
        os: "linux",
        cpuCount: 1,
        memorySize: 1024,
        diskSize: 1024,
        display: "1024x768"
    )
    config.setMacAddress("00:11:22:33:44:55")
    try vmDir.saveConfig(config)
    return vmDir
}

/// Restore the XDG_CONFIG_HOME env var the test changed. Use in a defer.
private func restoreXDGConfigHome(_ previous: String?) {
    if let previous {
        setenv("XDG_CONFIG_HOME", previous, 1)
    } else {
        unsetenv("XDG_CONFIG_HOME")
    }
}

// MARK: - Storage layer

@MainActor
@Test("VMMetadataStore round-trips creator/description/owner via the sidecar file")
func testVMMetadataRoundTrip() throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    let controller = try makeTestController(configDir: configDir, homeDir: homeDir)
    _ = try makeInitializedVMDir(in: homeDir, name: "alpha")

    let store = VMMetadataStore(home: controller.home)
    let input = VMMetadata(
        creator: "Or Zelig",
        description: "Authed harness base",
        owner: "Or Zelig"
    )

    let written = try store.save(input, name: "alpha")
    #expect(written.creator == "Or Zelig")
    #expect(written.description == "Authed harness base")
    #expect(written.owner == "Or Zelig")
    #expect(written.updatedAt != nil, "save() must stamp updated_at")

    let readBack = store.load(name: "alpha")
    #expect(readBack.creator == "Or Zelig")
    #expect(readBack.description == "Authed harness base")
    #expect(readBack.owner == "Or Zelig")
    #expect(readBack.updatedAt == written.updatedAt,
            "round-tripped updated_at must match what was written")
}

@MainActor
@Test("VMMetadataStore returns empty metadata when no sidecar exists")
func testVMMetadataMissingSidecar() throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    let controller = try makeTestController(configDir: configDir, homeDir: homeDir)
    _ = try makeInitializedVMDir(in: homeDir, name: "bare-vm")

    let store = VMMetadataStore(home: controller.home)
    let metadata = store.load(name: "bare-vm")

    // The contract: missing sidecar yields empty metadata, never throws.
    #expect(metadata.isEmpty)
    #expect(metadata.creator == nil)
    #expect(metadata.description == nil)
    #expect(metadata.owner == nil)
    #expect(metadata.updatedAt == nil)
}

@MainActor
@Test("VMMetadataStore.save ignores client-supplied updated_at and stamps current time")
func testVMMetadataServerStampsUpdatedAt() throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    let controller = try makeTestController(configDir: configDir, homeDir: homeDir)
    _ = try makeInitializedVMDir(in: homeDir, name: "stamped")

    let store = VMMetadataStore(home: controller.home)
    let bogus = VMMetadata(
        creator: "user",
        description: nil,
        owner: nil,
        updatedAt: "1999-01-01T00:00:00Z"  // year-1999 sentinel; server must not echo this
    )
    let written = try store.save(bogus, name: "stamped")

    #expect(written.updatedAt != "1999-01-01T00:00:00Z",
            "client-supplied updated_at must be discarded")
    // Sanity: a fresh ISO8601 timestamp must parse back into a Date later
    // than the bogus sentinel.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let writtenDate = formatter.date(from: written.updatedAt ?? "")
    #expect(writtenDate != nil, "server-set updated_at must be ISO8601-parsable")
    if let writtenDate {
        let sentinel = formatter.date(from: "1999-01-01T00:00:00Z")!
        #expect(writtenDate > sentinel)
    }
}

@MainActor
@Test("VMMetadataStore.save leaves no tmp file behind after a successful write")
func testVMMetadataNoTmpFileAfterWrite() throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    let controller = try makeTestController(configDir: configDir, homeDir: homeDir)
    let vmDir = try makeInitializedVMDir(in: homeDir, name: "atomic")
    let store = VMMetadataStore(home: controller.home)

    _ = try store.save(VMMetadata(creator: "x"), name: "atomic")

    // The atomic-write contract: temp file is renamed into place, leaving no
    // .tmp leftover. A second write must also leave nothing behind (this is
    // the path that goes through FileManager.replaceItemAt — different code
    // from the first-time write).
    let tmpPath = vmDir.dir.file("bushel-metadata.json.tmp").path
    #expect(!FileManager.default.fileExists(atPath: tmpPath),
            ".tmp file must not survive a successful write")

    _ = try store.save(VMMetadata(creator: "y"), name: "atomic")
    #expect(!FileManager.default.fileExists(atPath: tmpPath),
            ".tmp file must not survive an overwrite either")
}

// MARK: - HTTP handlers

@MainActor
@Test("GET /lume/vms/:name/metadata returns empty object when no sidecar exists")
func testHandleGetMetadataNoSidecar() async throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    _ = try makeTestController(configDir: configDir, homeDir: homeDir)
    // Server.init() creates its own LumeController, but since XDG_CONFIG_HOME
    // is set to the temp dir, the SettingsManager.shared inside it picks up
    // the same homeDir we just wrote.
    _ = try makeInitializedVMDir(in: homeDir, name: "needs-meta")

    let server = Server(port: 47820)
    let response = try await server.handleGetMetadata(name: "needs-meta", storage: nil)

    #expect(response.statusCode == .ok)
    let json = try JSONSerialization.jsonObject(with: response.body ?? Data()) as? [String: Any]
    #expect(json != nil, "expected JSON body")
    // All four fields are absent (the encoder emits explicit null for nils,
    // or omits them depending on Codable defaults — either is fine, both
    // mean "no metadata set"). The important thing is that creator/owner/
    // description don't carry stale values.
    #expect((json?["creator"] as? String) == nil)
    #expect((json?["owner"] as? String) == nil)
    #expect((json?["description"] as? String) == nil)
}

@MainActor
@Test("GET /lume/vms/:name/metadata returns 404 for an unknown VM")
func testHandleGetMetadataMissingVM() async throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    _ = try makeTestController(configDir: configDir, homeDir: homeDir)
    // Intentionally don't create a VM directory.

    let server = Server(port: 47821)
    let response = try await server.handleGetMetadata(name: "ghost", storage: nil)

    #expect(response.statusCode == .notFound)
}

@MainActor
@Test("PUT /lume/vms/:name/metadata persists the body and GET round-trips")
func testHandlePutThenGetMetadata() async throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    _ = try makeTestController(configDir: configDir, homeDir: homeDir)
    _ = try makeInitializedVMDir(in: homeDir, name: "putvm")

    let server = Server(port: 47822)

    let body = """
    {"creator":"Alice","description":"my vm","owner":"Bob","updated_at":"1999-01-01T00:00:00Z"}
    """.data(using: .utf8)!

    let putResp = try await server.handlePutMetadata(name: "putvm", storage: nil, body: body)
    #expect(putResp.statusCode == .ok)

    let putJSON = try JSONSerialization.jsonObject(with: putResp.body ?? Data()) as? [String: Any]
    #expect((putJSON?["creator"] as? String) == "Alice")
    #expect((putJSON?["description"] as? String) == "my vm")
    #expect((putJSON?["owner"] as? String) == "Bob")
    // The server discards the client's updated_at and stamps its own. Easiest
    // check: the response carries an updated_at that is NOT the sentinel.
    let echoedUpdatedAt = putJSON?["updated_at"] as? String
    #expect(echoedUpdatedAt != nil)
    #expect(echoedUpdatedAt != "1999-01-01T00:00:00Z")

    // Now read it back via GET — proves the sidecar is on disk and the
    // GET handler can find it.
    let getResp = try await server.handleGetMetadata(name: "putvm", storage: nil)
    #expect(getResp.statusCode == .ok)
    let getJSON = try JSONSerialization.jsonObject(with: getResp.body ?? Data()) as? [String: Any]
    #expect((getJSON?["creator"] as? String) == "Alice")
    #expect((getJSON?["description"] as? String) == "my vm")
    #expect((getJSON?["owner"] as? String) == "Bob")
    #expect((getJSON?["updated_at"] as? String) == echoedUpdatedAt,
            "GET must return the same updated_at that PUT stamped")
}

@MainActor
@Test("PUT /lume/vms/:name/metadata rejects malformed JSON with 400")
func testHandlePutMetadataMalformedBody() async throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    _ = try makeTestController(configDir: configDir, homeDir: homeDir)
    _ = try makeInitializedVMDir(in: homeDir, name: "bad-body")

    let server = Server(port: 47823)

    // Wrong type for creator — server must reject before touching disk.
    let body = #"{"creator": 42}"#.data(using: .utf8)!
    let resp = try await server.handlePutMetadata(name: "bad-body", storage: nil, body: body)
    #expect(resp.statusCode == .badRequest)

    // Empty body — also a 400, not a 500.
    let resp2 = try await server.handlePutMetadata(name: "bad-body", storage: nil, body: nil)
    #expect(resp2.statusCode == .badRequest)
}

@MainActor
@Test("PUT /lume/vms/:name/metadata returns 404 for an unknown VM")
func testHandlePutMetadataMissingVM() async throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    _ = try makeTestController(configDir: configDir, homeDir: homeDir)
    // No VM created — PUT must refuse to write a sidecar in mid-air.

    let server = Server(port: 47824)
    let body = #"{"creator":"x"}"#.data(using: .utf8)!
    let resp = try await server.handlePutMetadata(name: "nope", storage: nil, body: body)
    #expect(resp.statusCode == .notFound)
}

// MARK: - VMDetails embedding

@MainActor
@Test("VMDetails.metadata is populated from the sidecar when the VM is listed")
func testVMDetailsEmbedsMetadata() async throws {
    let configDir = try makeTempDir()
    let homeDir = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.removeItem(at: homeDir)
    }
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    defer { restoreXDGConfigHome(prev) }

    let controller = try makeTestController(configDir: configDir, homeDir: homeDir)
    _ = try makeInitializedVMDir(in: homeDir, name: "withmeta")

    // Write a sidecar directly so we exercise the read path (not the PUT
    // handler — that's already covered).
    let store = VMMetadataStore(home: controller.home)
    _ = try store.save(
        VMMetadata(creator: "Alice", description: "desc", owner: "Bob"),
        name: "withmeta"
    )

    let details = try controller.getDetails(name: "withmeta")
    #expect(details.metadata.creator == "Alice")
    #expect(details.metadata.description == "desc")
    #expect(details.metadata.owner == "Bob")

    // And it must encode through JSON (this is what /lume/vms returns and
    // what MCP's list_vms serializes for AI clients).
    let encoded = try JSONEncoder().encode(details)
    let obj = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let meta = obj?["metadata"] as? [String: Any]
    #expect(meta != nil)
    #expect((meta?["creator"] as? String) == "Alice")
    #expect((meta?["description"] as? String) == "desc")
    #expect((meta?["owner"] as? String) == "Bob")
}
