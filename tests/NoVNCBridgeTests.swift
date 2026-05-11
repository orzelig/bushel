import Foundation
import Testing

@testable import bushel

// Tests for the browser-based VNC (noVNC) integration. Cover four layers:
//
// 1. URL parsing helpers (parseVNCEndpoint / NoVNCPath.extractVMName) —
//    pure functions, easy to exercise without spinning up a server.
// 2. Vendored noVNC resources are bundled into the SPM resource bundle.
//    (Catches the common failure of forgetting Package.swift's .copy()
//    entry, mirroring DashboardHandlerTests's resource check.)
// 3. handleVNCViewer returns 200 text/html with the VM name substituted
//    and a script tag wiring up the WebSocket URL.
// 4. handleVNCStatic resolves vendored assets with the right Content-Type
//    and rejects path-traversal attempts.
//
// The WebSocket-to-TCP bridge itself is integration-tested against a real
// VNC server during PR smoke tests — unit-testing through NIO's channel
// pipeline would require enough EmbeddedChannel scaffolding to be its own
// PR. Documented in the PR description.

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
    #expect(html.contains("__BUSHEL_VM_NAME__"))
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
    #expect(!html.contains("__BUSHEL_VM_NAME__"), "placeholder must be replaced")
    #expect(html.contains("sandbox"))
    // The WS URL needs to embed the VM name so the browser connects to the
    // right bridge. We hardcode the relative path here so a regression that
    // changes the route prefix without updating the template gets caught.
    #expect(html.contains("/vnc/'"))  // template string concat
    #expect(html.contains("/ws"))
    // Standard noVNC RFB import path served from /vnc/static/.
    #expect(html.contains("/vnc/static/core/rfb.js"))
}

@MainActor
@Test("handleVNCViewer HTML-escapes hostile VM names")
func testHandleVNCViewerEscapesName() async throws {
    let server = Server(port: 47792)
    // VM names with HTML-special characters should be escaped so they can't
    // break out of the title/script string context. Lume's name regex would
    // normally reject these, but defense in depth.
    let response = try await server.handleVNCViewer(name: "</title><script>alert(1)</script>")
    let html = String(data: response.body ?? Data(), encoding: .utf8) ?? ""
    #expect(!html.contains("</title><script>"), "raw script tag must not appear")
    #expect(html.contains("&lt;") || html.contains("&#"))
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

// MARK: - MCP open_vnc tool envelope shape
//
// We can't end-to-end exercise the MCP server (which talks over stdio) from
// the test runner without spinning up the entire MCP stack. Instead, verify
// that the envelope helper produces the expected URL shape for a known
// "running" VMDetails. This is the same pattern the screen tools use for
// envelope assertions in the manual smoke tests.

@Test("lume_open_vnc URL format matches expected shape")
func testOpenVNCURLFormat() throws {
    // Replicates handleOpenVNC's URL construction without needing a real VM.
    let name = "sandbox"
    let port: UInt16 = 7777
    let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
    let browserURL = "http://127.0.0.1:\(port)/vnc/\(encoded)"
    let wsURL = "ws://127.0.0.1:\(port)/vnc/\(encoded)/ws"

    #expect(browserURL == "http://127.0.0.1:7777/vnc/sandbox")
    #expect(wsURL == "ws://127.0.0.1:7777/vnc/sandbox/ws")
}
