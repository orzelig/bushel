import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOWebSocket
import MCP

@testable import bushel

// Tests for the browser-based VNC (noVNC) integration. Cover five layers:
//
// 1. URL parsing helpers (parseVNCEndpoint / NoVNCPath.extractVMName) —
//    pure functions, easy to exercise without spinning up a server.
// 2. Vendored noVNC resources are bundled into the SPM resource bundle.
//    (Catches the common failure of forgetting Package.swift's .copy()
//    entry, mirroring DashboardHandlerTests's resource check.)
// 3. handleVNCViewer returns 200 text/html with the VM name substituted
//    and a script tag wiring up the WebSocket URL. Escape behaviour is
//    pinned to specific entity strings and raw-char absences, not
//    `|| contains("&#")` (the old form was a tautology against payloads
//    containing single quotes).
// 4. handleVNCStatic resolves vendored assets with the right Content-Type
//    and rejects path-traversal attempts.
// 5. wireBridge (the pure pipeline-wireup half of installVNCBridge) routes
//    bytes both directions over an EmbeddedChannel pair and cascades close.
//    The pre-refactor code couldn't be tested this way because the pipeline
//    install was tangled with MainActor lookup and TCP-connect.

// MARK: - Pure URL parsing

@Test("parseVNCEndpoint extracts host/port/password from vnc:// scheme")
func testParseVNCEndpointBasic() throws {
    let endpoint = try parseVNCEndpoint("vnc://:hunter2@127.0.0.1:57413")
    #expect(endpoint.host == "127.0.0.1")
    #expect(endpoint.port == 57413)
    #expect(endpoint.password == "hunter2")
}

@Test("parseVNCEndpoint handles passwords with URL-safe characters")
func testParseVNCEndpointPassword() throws {
    // lume generates passwords from a printable charset that doesn't include
    // URL reserved chars, but a synthetic password with hyphens should still parse.
    let endpoint = try parseVNCEndpoint("vnc://:abc-DEF-123@127.0.0.1:62295")
    #expect(endpoint.password == "abc-DEF-123")
    #expect(endpoint.port == 62295)
}

@Test("parseVNCEndpoint rejects malformed URLs")
func testParseVNCEndpointMalformed() {
    // Missing port
    #expect(throws: VNCEndpointParseError.self) {
        try parseVNCEndpoint("vnc://:pw@127.0.0.1")
    }
    // Not a URL at all
    #expect(throws: VNCEndpointParseError.self) {
        try parseVNCEndpoint("not a url")
    }
}

@Test("NoVNCPath.extractVMName matches /vnc/<name>/ws")
func testExtractVMNameValid() {
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/vnc/sandbox/ws") == "sandbox")
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/vnc/my-vm/ws") == "my-vm")
    // Query string tolerated.
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/vnc/sandbox/ws?foo=bar") == "sandbox")
    // URL-encoded name (e.g. "macos sequoia" → "macos%20sequoia") should round-trip.
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/vnc/macos%20sequoia/ws") == "macos sequoia")
}

@Test("NoVNCPath.extractVMName rejects non-matching paths")
func testExtractVMNameInvalid() {
    // Wrong depth.
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/vnc/sandbox") == nil)
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/vnc/sandbox/ws/extra") == nil)
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/") == nil)
    // Static asset prefix must not match — those go through the HTTP handler.
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/vnc/static/ws") == nil)
    // Different prefix.
    #expect(NoVNCPath.extractVMName(fromWebSocketPath: "/lume/sandbox/ws") == nil)
}

// MARK: - Resource bundle

@Test("noVNC viewer HTML is bundled into the SPM resource bundle")
func testNoVNCViewerResourceBundled() throws {
    let url = Bundle.lumeResources.url(forResource: "novnc/vnc", withExtension: "html")
    #expect(url != nil, "novnc/vnc.html must be present in the SPM resource bundle")
    let data = try Data(contentsOf: url!)
    #expect(!data.isEmpty)
    let html = String(data: data, encoding: .utf8) ?? ""
    // Sentinels from the vendored HTML — fail loudly if the file is replaced
    // with something that doesn't render the WS connect URL or RFB import.
    // The two placeholders are split-by-context (HTML vs JS); we check both
    // so a future regression that drops one isn't silent.
    #expect(html.contains("__BUSHEL_VM_NAME_HTML__"))
    #expect(html.contains("__BUSHEL_VM_NAME_JSON__"))
    #expect(html.contains("/vnc/static/core/rfb.js"))
    #expect(html.contains("/vnc/") && html.contains("/ws"))
}

@Test("vendored noVNC core/rfb.js is bundled")
func testNoVNCCoreJSBundled() throws {
    // Sanity check that the vendored noVNC core/ directory is actually
    // shipped — without this, the viewer HTML would render but fail to
    // execute the RFB import.
    guard let bundleURL = Bundle.lumeResources.resourceURL else {
        Issue.record("resourceURL missing from Bundle.lumeResources")
        return
    }
    let rfbPath = bundleURL.appendingPathComponent("novnc/core/rfb.js")
    let data = try Data(contentsOf: rfbPath)
    #expect(data.count > 1000, "core/rfb.js should be substantial — got \(data.count) bytes")
    let js = String(data: data, encoding: .utf8) ?? ""
    #expect(js.contains("class RFB") || js.contains("export default"))
}

// MARK: - HTML handler

@MainActor
@Test("handleVNCViewer returns 200 text/html with the VM name substituted")
func testHandleVNCViewerSubstitutesName() async throws {
    let server = Server(port: 47791)
    let response = try await server.handleVNCViewer(name: "sandbox")

    #expect(response.statusCode == .ok)
    let contentType = response.headers["Content-Type"] ?? ""
    #expect(contentType.contains("text/html"))
    #expect(response.body != nil)

    let html = String(data: response.body ?? Data(), encoding: .utf8) ?? ""
    // Both placeholders must have been replaced.
    #expect(!html.contains("__BUSHEL_VM_NAME_HTML__"), "HTML placeholder must be replaced")
    #expect(!html.contains("__BUSHEL_VM_NAME_JSON__"), "JSON placeholder must be replaced")
    #expect(html.contains("sandbox"))
    // The WS URL needs to embed the VM name so the browser connects to the
    // right bridge. We hardcode the relative path here so a regression that
    // changes the route prefix without updating the template gets caught.
    #expect(html.contains("/vnc/'"))  // template string concat
    #expect(html.contains("/ws"))
    // Standard noVNC RFB import path served from /vnc/static/.
    #expect(html.contains("/vnc/static/core/rfb.js"))
    // JSON-encoded JS literal form — string with surrounding quotes.
    #expect(html.contains("const VM_NAME = \"sandbox\""))
}

@MainActor
@Test("handleVNCViewer escapes hostile VM names per-context")
func testHandleVNCViewerEscapesName() async throws {
    let server = Server(port: 47792)
    // Payload designed to exercise every escape: literal `&`, `"`, `<`, `>`,
    // `'`, and a unicode char. Lume's name regex would normally reject these,
    // but defense in depth — the daemon should still produce safe HTML.
    let payload = "&\"<>'>foo"
    let response = try await server.handleVNCViewer(name: payload)
    let html = String(data: response.body ?? Data(), encoding: .utf8) ?? ""

    // Each character we care about must have its specific entity present.
    // Previously this test was `contains("&lt;") || contains("&#")` — the
    // `||` was vacuously true for any payload with a `'` (always escaped as
    // `&#39;`), so a regression that stopped escaping `<` would not have
    // surfaced. Pin each entity explicitly.
    #expect(html.contains("&amp;"), "& must be escaped")
    #expect(html.contains("&lt;"), "< must be escaped in HTML contexts")
    #expect(html.contains("&gt;"), "> must be escaped in HTML contexts")
    #expect(html.contains("&quot;"), "\" must be escaped in HTML contexts")
    #expect(html.contains("&#39;"), "' must be escaped in HTML contexts")

    // And the raw characters that would have broken out of the tag must be
    // absent in *attribute/text* contexts. We don't assert "absent in entire
    // file" because the JSON-encoded version legitimately includes `&`/`<`
    // inside the JS string literal (where they're harmless — JS doesn't
    // interpret HTML special chars). Instead, sentinel exactly the substrings
    // that would indicate a successful break-out.
    #expect(!html.contains("<script>"), "raw <script> must not appear")
    #expect(!html.contains("\"onerror"), "\"onerror= injection must not appear")
    #expect(!html.contains("'><"), "'>< injection must not appear")

    // JS context: the JSON-encoded form must contain the *literal* characters
    // (not HTML entities). A previous bug double-encoded the JS literal so
    // `foo&bar` became `foo&amp;bar` and the resulting WS URL was wrong.
    #expect(html.contains("const VM_NAME = "), "VM_NAME assignment present")
    // JSONEncoder escapes `"` as `\"` and `<` as `<` (forward-slash
    // safety mode). The substring `\"<>` would never appear in a JSON string,
    // but `<` would normally remain literal — JSONEncoder happens to escape
    // it as `<`. Either way, the literal HTML entity strings should NOT
    // be present in the JS string literal value.
    #expect(!html.contains("VM_NAME = \"&amp;\""), "JS context must not be HTML-escaped")
}

@MainActor
@Test("handleVNCViewer JSON-encodes unicode in the JS literal")
func testHandleVNCViewerJSONEncodesUnicode() async throws {
    let server = Server(port: 47796)
    // Unicode char (é, U+00E9) — must not get HTML-entity-encoded and must
    // be valid in a JS string literal. JSONEncoder emits it as the literal
    // codepoint (UTF-8 in the output bytes), which is JS-valid.
    let response = try await server.handleVNCViewer(name: "caf\u{00E9}")
    let html = String(data: response.body ?? Data(), encoding: .utf8) ?? ""
    // The HTML context preserves unicode unchanged (it's not in the escape set).
    #expect(html.contains("caf\u{00E9}"))
    // The JS literal must form a valid quoted string containing the char.
    #expect(html.contains("const VM_NAME = \"caf\u{00E9}\""))
}

// MARK: - Static asset handler

@MainActor
@Test("handleVNCStatic serves core/rfb.js with application/javascript")
func testHandleVNCStaticServesJS() async throws {
    let server = Server(port: 47793)
    let response = await server.handleVNCStatic(assetPath: "core/rfb.js")
    #expect(response.statusCode == .ok)
    let contentType = response.headers["Content-Type"] ?? ""
    #expect(contentType.contains("javascript"))
    #expect((response.body?.count ?? 0) > 0)
}

@MainActor
@Test("handleVNCStatic rejects path traversal")
func testHandleVNCStaticRejectsTraversal() async {
    let server = Server(port: 47794)

    // ".." segments are rejected outright.
    let resp1 = await server.handleVNCStatic(assetPath: "../dashboard.html")
    #expect(resp1.statusCode == .badRequest)

    // Leading "/" rejected.
    let resp2 = await server.handleVNCStatic(assetPath: "/etc/passwd")
    #expect(resp2.statusCode == .badRequest)

    // Empty path → bad request.
    let resp3 = await server.handleVNCStatic(assetPath: "")
    #expect(resp3.statusCode == .badRequest)
}

@MainActor
@Test("handleVNCStatic returns 404 for missing assets")
func testHandleVNCStaticMissing() async {
    let server = Server(port: 47795)
    let response = await server.handleVNCStatic(assetPath: "core/this-file-does-not-exist.js")
    #expect(response.statusCode == .notFound)
}

// MARK: - MCP open_vnc envelope (via buildOpenVNCResult helper)
//
// handleOpenVNC's logic was extracted into buildOpenVNCResult so we can
// exercise it without standing up a real LumeController. The previous test
// in this file ("testOpenVNCURLFormat") replicated the URL formula in the
// test body itself — a tautology that couldn't catch a regression where
// the production code stopped percent-encoding or changed the scheme.

private func makeVMDetails(
    name: String = "sandbox",
    status: String = "running",
    vncUrl: String? = "vnc://:hunter2@127.0.0.1:57413"
) -> VMDetails {
    VMDetails(
        name: name,
        os: "macos",
        cpuCount: 2,
        memorySize: 4 * 1024 * 1024 * 1024,
        diskSize: .init(allocated: 0, total: 64 * 1024 * 1024 * 1024),
        display: "1024x768",
        status: status,
        vncUrl: vncUrl,
        ipAddress: "192.0.2.1",
        locationName: "default"
    )
}

private func decodeMCPEnvelope(_ result: MCP.CallTool.Result) throws -> [String: Any] {
    // The envelope's JSON lives in the first .text content. Decode and
    // return as a generic dict so individual tests can pluck the fields
    // they care about.
    for c in result.content {
        if case let .text(text, _, _) = c {
            let data = text.data(using: .utf8) ?? Data()
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
    }
    return [:]
}

@MainActor
@Test("lume_open_vnc returns expected URL shape for a running VM")
func testOpenVNCURLShape() throws {
    let vm = makeVMDetails(name: "sandbox", status: "running",
                           vncUrl: "vnc://:hunter2@127.0.0.1:57413")
    let result = LumeMCPServer.buildOpenVNCResult(name: "sandbox", vm: vm, includePassword: false)

    let envelope = try decodeMCPEnvelope(result)
    #expect((envelope["ok"] as? Bool) == true)
    #expect((envelope["operation"] as? String) == "open_vnc")
    let payload = envelope["result"] as? [String: Any] ?? [:]
    #expect((payload["name"] as? String) == "sandbox")
    #expect((payload["url"] as? String) == "http://127.0.0.1:7777/vnc/sandbox")
    #expect((payload["ws_url"] as? String) == "ws://127.0.0.1:7777/vnc/sandbox/ws")
}

@MainActor
@Test("lume_open_vnc percent-encodes VM names with spaces")
func testOpenVNCURLEncodesSpaces() throws {
    // The URL builder must percent-encode the VM name. A regression that
    // strips this would land the raw space in the URL and break the browser
    // (and bridge path-match). This is the assertion the previous tautology
    // test couldn't make.
    let vm = makeVMDetails(name: "macos sequoia", status: "running")
    let result = LumeMCPServer.buildOpenVNCResult(name: "macos sequoia",
                                                   vm: vm, includePassword: false)
    let envelope = try decodeMCPEnvelope(result)
    let payload = envelope["result"] as? [String: Any] ?? [:]
    let url = (payload["url"] as? String) ?? ""
    let wsURL = (payload["ws_url"] as? String) ?? ""
    #expect(url.contains("/vnc/macos%20sequoia"), "expected %20 in URL, got: \(url)")
    #expect(wsURL.contains("/vnc/macos%20sequoia/ws"), "expected %20 in WS URL, got: \(wsURL)")
}

@MainActor
@Test("lume_open_vnc redacts password by default")
func testOpenVNCRedactsPasswordByDefault() throws {
    let vm = makeVMDetails(vncUrl: "vnc://:supersecret@127.0.0.1:57413")
    let result = LumeMCPServer.buildOpenVNCResult(name: "sandbox", vm: vm, includePassword: false)

    let envelope = try decodeMCPEnvelope(result)
    let payload = envelope["result"] as? [String: Any] ?? [:]
    let native = (payload["native_vnc_url"] as? String) ?? ""
    // The password must not appear anywhere in the envelope.
    #expect(!native.contains("supersecret"), "password leaked: \(native)")
    // The host:port form should still be present so the URL is actionable.
    #expect(native.contains("127.0.0.1:57413"))
    #expect(native.hasPrefix("vnc://"))
}

@MainActor
@Test("lume_open_vnc surfaces password when include_password is true")
func testOpenVNCIncludesPasswordWhenOptedIn() throws {
    let vm = makeVMDetails(vncUrl: "vnc://:supersecret@127.0.0.1:57413")
    let result = LumeMCPServer.buildOpenVNCResult(name: "sandbox", vm: vm, includePassword: true)

    let envelope = try decodeMCPEnvelope(result)
    let payload = envelope["result"] as? [String: Any] ?? [:]
    let native = (payload["native_vnc_url"] as? String) ?? ""
    #expect(native == "vnc://:supersecret@127.0.0.1:57413")
}

@MainActor
@Test("lume_open_vnc returns vnc_unavailable for stopped VM")
func testOpenVNCErrorStopped() throws {
    let vm = makeVMDetails(status: "stopped")
    let result = LumeMCPServer.buildOpenVNCResult(name: "sandbox", vm: vm, includePassword: false)
    let envelope = try decodeMCPEnvelope(result)
    #expect((envelope["ok"] as? Bool) == false)
    let err = envelope["error"] as? [String: Any] ?? [:]
    #expect((err["code"] as? String) == "vnc_unavailable")
}

@MainActor
@Test("lume_open_vnc returns vnc_unavailable when VM has no vncUrl")
func testOpenVNCErrorNoVNCURL() throws {
    let vm = makeVMDetails(status: "running", vncUrl: nil)
    let result = LumeMCPServer.buildOpenVNCResult(name: "sandbox", vm: vm, includePassword: false)
    let envelope = try decodeMCPEnvelope(result)
    #expect((envelope["ok"] as? Bool) == false)
    let err = envelope["error"] as? [String: Any] ?? [:]
    #expect((err["code"] as? String) == "vnc_unavailable")
}

@MainActor
@Test("redactVNCURLPassword strips userinfo, preserves host/port/scheme")
func testRedactVNCURLPassword() {
    let redacted = LumeMCPServer.redactVNCURLPassword("vnc://:hunter2@127.0.0.1:5900")
    // URL stays a vnc:// URL, host:port preserved, password gone.
    #expect(!redacted.contains("hunter2"))
    #expect(redacted.contains("127.0.0.1:5900"))
    #expect(redacted.hasPrefix("vnc://"))
}

// MARK: - WebSocket-to-TCP bridge (EmbeddedChannel)
//
// Pre-refactor, installVNCBridge wove together MainActor resolution, TCP
// connect, pipeline install, and close-cascade in one function — none of
// which could be unit-tested with EmbeddedChannel. The pipeline-wireup
// logic was hoisted into wireBridge(ws:, tcp:, vmName:), which works
// against any pair of Channels — including two EmbeddedChannels.

@Test("WS↔TCP bridge forwards bytes in both directions and cascades close")
func testBridgeBytestream() throws {
    let tcp = EmbeddedChannel()
    let ws = EmbeddedChannel()
    // The WS side has a frame decoder/encoder in a real pipeline; here we
    // feed pre-decoded WebSocketFrame inbound values directly into the WS
    // channel and observe outbound WebSocketFrames produced by the TCP→WS
    // handler. This is exactly the same handler the production wireBridge
    // installs, just with the framing layer collapsed into manual frame
    // construction.

    try wireBridge(ws: ws, tcp: tcp, vmName: "t").wait()

    // browser → VM: a binary frame in becomes raw bytes out on the TCP side.
    let payload = ByteBuffer(string: "RFB 003.008\n")
    let inbound = WebSocketFrame(fin: true, opcode: .binary, data: payload)
    try ws.writeInbound(inbound)
    let tcpOut: ByteBuffer = try #require(try tcp.readOutbound())
    #expect(tcpOut.getString(at: 0, length: tcpOut.readableBytes) == "RFB 003.008\n")

    // VM → browser: bytes in on the TCP side become a binary frame on WS.
    try tcp.writeInbound(ByteBuffer(string: "PONG"))
    let wsOut: WebSocketFrame = try #require(try ws.readOutbound())
    #expect(wsOut.opcode == .binary)
    let wsBytes = wsOut.data
    #expect(wsBytes.getString(at: 0, length: wsBytes.readableBytes) == "PONG")

    // Closing the WS side must cascade to the TCP side. EmbeddedChannel.close
    // is synchronous-completing; afterward, tcp.isActive must be false.
    try ws.close().wait()
    #expect(!tcp.isActive)
}

@Test("WS→TCP bridge handles a connectionClose frame by closing both sides")
func testBridgeCloseFrame() throws {
    let tcp = EmbeddedChannel()
    let ws = EmbeddedChannel()
    try wireBridge(ws: ws, tcp: tcp, vmName: "t").wait()

    // A close frame from the browser should tear down the TCP side. The
    // close-frame echo on the WS side races channel teardown in
    // EmbeddedChannel; we only assert that TCP gets closed (the production
    // contract that matters — no leaked TCP connection to the VM).
    let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
    try ws.writeInbound(close)
    #expect(!tcp.isActive)
}

// MARK: - BridgeRegistry concurrency caps

@Test("BridgeRegistry per-VM cap blocks the (maxPerVM+1)th acquire")
func testBridgeRegistryPerVMCap() async {
    let registry = BridgeRegistry()
    let vm = "isolated-test-vm"
    // Even though `maxPerVM` is `let`, Swift 6 still treats actor-stored
    // properties as isolated unless explicitly marked `nonisolated`. Hop in.
    let cap = await registry.maxPerVM
    for _ in 0..<cap {
        let ok = await registry.tryAcquire(vmName: vm)
        #expect(ok)
    }
    let overflow = await registry.tryAcquire(vmName: vm)
    #expect(!overflow)
    // Releasing one slot frees a new acquire.
    await registry.release(vmName: vm)
    let recoveredAcquire = await registry.tryAcquire(vmName: vm)
    #expect(recoveredAcquire)
}
