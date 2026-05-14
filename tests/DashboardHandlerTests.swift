import Foundation
import Testing

@testable import bushel

// Tests for the built-in dashboard handler. We test two things:
//
// 1. The dashboard.html resource is actually bundled into the SPM resource
//    bundle (catches the common failure of forgetting Package.swift's
//    .copy("Resources/dashboard.html") entry).
//
// 2. handleDashboard() returns 200 with text/html content and a non-empty
//    body that looks like our HTML page (sanity check on the wiring).

@Test("dashboard.html resource is bundled and loadable")
func testDashboardResourceBundled() throws {
    let url = Bundle.lumeResources.url(forResource: "dashboard", withExtension: "html")
    #expect(url != nil, "dashboard.html must be present in the SPM resource bundle")
    let data = try Data(contentsOf: url!)
    #expect(!data.isEmpty)
    let html = String(data: data, encoding: .utf8) ?? ""
    #expect(html.lowercased().contains("<!doctype html>"))
    // Sentinels from the dashboard HTML — fail loudly if the file gets replaced
    // with something that doesn't actually render the VM list.
    #expect(html.contains("bushel"))
    #expect(html.contains("/lume/vms"))
}

@Test("dashboard.html contains the parity-feature buttons")
func testDashboardHasParityButtons() throws {
    // Buttons added in the dashboard-parity PR. Smoke-checks that the
    // toolbar/footer wiring didn't regress — the actual click behaviour
    // is JS-driven and not unit-testable from Swift.
    let url = Bundle.lumeResources.url(forResource: "dashboard", withExtension: "html")
    let html = String(data: try Data(contentsOf: url!), encoding: .utf8) ?? ""
    #expect(html.contains("+ Create VM"), "Create VM toolbar button missing")
    #expect(html.contains("Edit settings"), "Edit-settings card button missing")
    #expect(html.contains("Clone"), "Clone card button missing")
    #expect(html.contains("Copy SSH"), "Copy SSH card button missing")
}

@Test("dashboard.html contains the parity-feature dialog IDs")
func testDashboardHasParityDialogIDs() throws {
    // The three new <dialog> elements wired in the dashboard-parity PR.
    // The metadata dialog from #18 keeps its own id (metadata-dialog).
    let url = Bundle.lumeResources.url(forResource: "dashboard", withExtension: "html")
    let html = String(data: try Data(contentsOf: url!), encoding: .utf8) ?? ""
    #expect(html.contains("id=\"dlg-create\""), "dlg-create dialog missing")
    #expect(html.contains("id=\"dlg-edit\""), "dlg-edit dialog missing")
    #expect(html.contains("id=\"dlg-clone\""), "dlg-clone dialog missing")
}

@MainActor
@Test("handleDashboard returns 200 with HTML content type and a non-empty body")
func testDashboardHandlerReturnsHTML() async throws {
    // Pick an unlikely-to-be-bound port. Server.init() does not bind; only
    // start() does, and we never call it here.
    let server = Server(port: 47789)
    let response = try await server.handleDashboard()

    #expect(response.statusCode == .ok)
    let contentType = response.headers["Content-Type"] ?? ""
    #expect(contentType.contains("text/html"))
    #expect(response.body != nil)
    let body = response.body ?? Data()
    #expect(!body.isEmpty)

    let html = String(data: body, encoding: .utf8) ?? ""
    #expect(html.contains("bushel"))
    #expect(html.contains("/lume/vms"))
}

@MainActor
@Test("handleDashboard sets a no-cache directive so upgrades aren't masked by stale UI")
func testDashboardSendsNoCache() async throws {
    let server = Server(port: 47790)
    let response = try await server.handleDashboard()
    let cacheControl = response.headers["Cache-Control"] ?? ""
    #expect(cacheControl.contains("no-cache"))
}
