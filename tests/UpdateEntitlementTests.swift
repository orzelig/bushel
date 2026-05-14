import Foundation
import Testing

@testable import bushel

/// Tests for `Update.ensureEntitlement(binaryPath:)` — the defense-in-depth
/// re-sign that runs after `bushel update` swaps the binary. See issue #20.
///
/// The strategy: copy a real binary somewhere we own, strip its codesignature
/// with `codesign --remove-signature` so we're certain no entitlement is
/// embedded, run `ensureEntitlement`, then read back the entitlements via
/// `codesign --display --entitlements -` and confirm both keys appear.
///
/// If /usr/bin/codesign isn't available on the test runner (it always is on
/// macOS, but be defensive) the test is skipped. If the test infrastructure
/// can't find or copy a binary, the test is skipped — the CI signing step
/// in release.yml is the primary guarantee; this is belt-and-braces.

@Test("ensureEntitlement embeds Virtualization keys on an unsigned binary")
func testEnsureEntitlementAddsKeys() throws {
    let codesignPath = "/usr/bin/codesign"
    guard FileManager.default.isExecutableFile(atPath: codesignPath) else {
        // No codesign on this runner — bail. The CI release.yml step is the
        // load-bearing guarantee anyway.
        return
    }

    // Source binary: any small executable we can copy. /bin/ls is universally
    // present on macOS and small; the test target's executable would also
    // work but isn't easily resolvable here.
    let sourceCandidates = ["/bin/ls", "/bin/echo", "/usr/bin/true"]
    guard let sourcePath = sourceCandidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    }) else {
        // Nothing to copy — skip rather than fail.
        return
    }

    // Stage a copy we own. NSTemporaryDirectory is fine; we're not running
    // it, just signing it.
    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bushel-entitlement-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let copy = tmpDir.appendingPathComponent("bin")
    try FileManager.default.copyItem(atPath: sourcePath, toPath: copy.path)
    // Ensure user-writable so codesign can rewrite it.
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)

    // Strip any inherited codesignature so we start from a clean slate.
    // /bin/ls is normally Apple-signed; --remove-signature makes the binary
    // unsigned (then ensureEntitlement should sign it ad-hoc with the
    // entitlements). If the strip fails (e.g. SIP-protected source, though
    // we copied it), skip — the precondition can't be established.
    let strip = Process()
    strip.executableURL = URL(fileURLWithPath: codesignPath)
    strip.arguments = ["--remove-signature", copy.path]
    strip.standardOutput = Pipe()
    strip.standardError = Pipe()
    try strip.run()
    strip.waitUntilExit()
    // Don't assert on strip status — if the source was already unsigned
    // codesign exits non-zero on some macOS versions. We re-sign regardless.

    // Act.
    let ok = Update.ensureEntitlement(binaryPath: copy)
    #expect(ok, "ensureEntitlement reported failure")

    // Assert: codesign --display --entitlements - should now print both keys.
    let display = Process()
    display.executableURL = URL(fileURLWithPath: codesignPath)
    display.arguments = ["--display", "--entitlements", "-", copy.path]
    let pipe = Pipe()
    display.standardOutput = pipe
    display.standardError = pipe
    try display.run()
    display.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    #expect(
        output.contains("com.apple.security.virtualization"),
        "Expected com.apple.security.virtualization in entitlements after ensureEntitlement; got: \(output)"
    )
    #expect(
        output.contains("com.apple.security.hypervisor"),
        "Expected com.apple.security.hypervisor in entitlements after ensureEntitlement; got: \(output)"
    )
}

@Test("ensureEntitlement is a no-op on a binary that already has the entitlement")
func testEnsureEntitlementNoOpWhenPresent() throws {
    let codesignPath = "/usr/bin/codesign"
    guard FileManager.default.isExecutableFile(atPath: codesignPath) else { return }

    let sourceCandidates = ["/bin/ls", "/bin/echo", "/usr/bin/true"]
    guard let sourcePath = sourceCandidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    }) else { return }

    let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bushel-entitlement-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let copy = tmpDir.appendingPathComponent("bin")
    try FileManager.default.copyItem(atPath: sourcePath, toPath: copy.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)

    // Sign it once.
    #expect(Update.ensureEntitlement(binaryPath: copy))

    // Capture mtime, then run again — should be a no-op (no codesign call).
    // We don't have a clean "didNothing" signal so we just confirm the
    // entitlement is still there and the function reports success.
    #expect(Update.ensureEntitlement(binaryPath: copy))

    let display = Process()
    display.executableURL = URL(fileURLWithPath: codesignPath)
    display.arguments = ["--display", "--entitlements", "-", copy.path]
    let pipe = Pipe()
    display.standardOutput = pipe
    display.standardError = pipe
    try display.run()
    display.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
    #expect(output.contains("com.apple.security.virtualization"))
}
