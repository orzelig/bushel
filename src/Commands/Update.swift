import ArgumentParser
import Foundation

/// `bushel update` — checks GitHub Releases for a newer bushel and applies it
/// after the user confirms. SHA-256 is verified against the published sidecar
/// before swapping any files. Daemon is unloaded around the swap so it doesn't
/// keep an open handle on the old binary.
///
/// v1 scope: explicit user-invoked. A scheduled checker (LaunchAgent that runs
/// `bushel update --check-only --notify` and surfaces a macOS notification when
/// an update is available) is a future addition.
struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for and install a newer bushel release.",
        discussion: """
            Talks to https://api.github.com/repos/orzelig/bushel/releases/latest,
            compares to the running version, and (if newer) downloads the
            release tarball, verifies its SHA-256, and swaps it in place.

            By default this prompts before applying. Pass --yes for non-
            interactive use, or --check-only to just see whether an update is
            pending without applying anything.
            """
    )

    @Flag(name: .long, help: "Apply the update without prompting (use in scripts).")
    var yes: Bool = false

    @Flag(name: .long, help: "Only check whether an update is available; exit 0 if up-to-date, exit 1 if newer release available.")
    var checkOnly: Bool = false

    @Flag(name: .long, help: "When combined with --check-only, post a macOS notification if an update is available. The LaunchAgent installer wires this up for the daily background check.")
    var notify: Bool = false

    func run() async throws {
        let current = Lume.Version.current
        print("Current: \(current)")

        let latest = try await fetchLatestTag()
        let latestVersion = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
        print("Latest:  \(latestVersion)")

        if latestVersion == current {
            print("Up to date.")
            return
        }

        // Different (newer or older — we don't strictly compare semver here, since
        // bushel-prerelease versioning sorts oddly. We surface the difference and
        // let the user decide.).
        print("")
        print("A different release is available: \(latest)")
        print("https://github.com/orzelig/bushel/releases/tag/\(latest)")

        if checkOnly {
            if notify {
                postUpdateNotification(current: current, latest: latest)
            }
            // Exit code 1 signals "update available" to shell scripts.
            throw ExitCode(1)
        }

        if !yes {
            print("")
            printConfirmPrompt()
            guard readYes() else {
                print("Cancelled.")
                return
            }
        }

        try await applyUpdate(tag: latest)
    }

    // MARK: - Latest release lookup

    private func fetchLatestTag() async throws -> String {
        struct Release: Decodable { let tag_name: String }
        let url = URL(string: "https://api.github.com/repos/orzelig/bushel/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("bushel-update/\(Lume.Version.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.networkFailure("GitHub API returned non-200")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.tag_name
    }

    // MARK: - Apply update

    private func applyUpdate(tag: String) async throws {
        let tarballURL = URL(string: "https://github.com/orzelig/bushel/releases/download/\(tag)/bushel-darwin-arm64.tar.gz")!
        let shaURL = URL(string: "https://github.com/orzelig/bushel/releases/download/\(tag)/bushel-darwin-arm64.tar.gz.sha256")!

        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        print("Downloading tarball...")
        let tarPath = tmpDir.appendingPathComponent("bushel.tar.gz")
        try await download(from: tarballURL, to: tarPath)

        print("Verifying SHA-256...")
        let expectedSha = try await fetchExpectedSHA(from: shaURL)
        let actualSha = try sha256(of: tarPath)
        guard expectedSha == actualSha else {
            throw UpdateError.shaMismatch(expected: expectedSha, actual: actualSha)
        }
        print("  match: \(actualSha.prefix(16))…")

        print("Extracting...")
        try runCommand("/usr/bin/tar", ["-xzf", tarPath.path, "-C", tmpDir.path])

        // Resolve the running binary's location and the bundle alongside it.
        guard let runningPath = Bundle.main.executablePath else {
            throw UpdateError.cannotResolveInstall("Bundle.main.executablePath is nil")
        }
        let installURL = URL(fileURLWithPath: runningPath)
        let installDir = installURL.deletingLastPathComponent()
        let bundleURL = installDir.appendingPathComponent("bushel_bushel.bundle")

        // Locate the new binary + bundle in the extracted tree.
        let newBinary = tmpDir.appendingPathComponent("bushel")
        let newBundle = tmpDir.appendingPathComponent("bushel_bushel.bundle")
        guard FileManager.default.fileExists(atPath: newBinary.path) else {
            throw UpdateError.malformedTarball("missing 'bushel' at top level of extract")
        }

        // Daemon-handoff: stop -> swap -> start. If anything between stop and
        // start fails, we still try to start the (possibly old) daemon back so
        // the user isn't left without one.
        let plist = ("\(NSHomeDirectory())/Library/LaunchAgents/io.github.orzelig.bushel.daemon.plist")
        let daemonWasLoaded = FileManager.default.fileExists(atPath: plist)
        if daemonWasLoaded {
            print("Stopping daemon...")
            try? runCommand("/bin/launchctl", ["unload", plist])
        }

        do {
            print("Swapping binary -> \(installURL.path)")
            // /usr/bin/install preserves perms; rename can fail across volumes.
            try runCommand("/usr/bin/install", ["-m", "0755", newBinary.path, installURL.path])

            if FileManager.default.fileExists(atPath: newBundle.path) {
                print("Swapping resource bundle -> \(bundleURL.path)")
                try? FileManager.default.removeItem(at: bundleURL)
                try FileManager.default.copyItem(at: newBundle, to: bundleURL)
            }

            // Defense-in-depth (issue #20): catches users upgrading from
            // unsigned builds and any future CI signing regression. Best
            // effort — we log on failure rather than bailing mid-swap so
            // the daemon still gets restarted.
            Update.ensureEntitlement(binaryPath: installURL)
        } catch {
            // Best effort: bring the daemon back up even if the swap was partial.
            if daemonWasLoaded {
                try? runCommand("/bin/launchctl", ["load", plist])
            }
            throw error
        }

        if daemonWasLoaded {
            print("Starting daemon...")
            try runCommand("/bin/launchctl", ["load", plist])
        }

        print("")
        print("Updated to \(tag).")
    }

    // MARK: - Helpers

    private func printConfirmPrompt() {
        print("Apply this update? Daemon will be restarted (in-flight ops may be interrupted). [y/N]: ", terminator: "")
        // ArgumentParser stdout isn't auto-flushed in some terminal setups.
        FileHandle.standardOutput.write(Data())
    }

    private func readYes() -> Bool {
        guard let line = readLine(strippingNewline: true) else { return false }
        let normalized = line.trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "y" || normalized == "yes"
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bushel-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func download(from url: URL, to path: URL) async throws {
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.networkFailure("download \(url.path) returned \(http.statusCode)")
        }
        // URLSession.download writes to a temp path; move into our tmpDir.
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        try FileManager.default.moveItem(at: downloaded, to: path)
    }

    private func fetchExpectedSHA(from url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.networkFailure("sha sidecar \(url.path) returned \(http.statusCode)")
        }
        // sha256sum format: "<hash>  <filename>". Take the first whitespace-split token.
        guard let text = String(data: data, encoding: .utf8) else {
            throw UpdateError.malformedSha("sidecar isn't UTF-8")
        }
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first else {
            throw UpdateError.malformedSha("sidecar has no hash field")
        }
        return String(token).lowercased()
    }

    private func sha256(of file: URL) throws -> String {
        // shasum is shipped with macOS; avoids dragging CommonCrypto into
        // ArgumentParser-land for a single hash.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", file.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.malformedSha("shasum exited \(process.terminationStatus)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let line = String(data: data, encoding: .utf8),
              let token = line.split(whereSeparator: { $0.isWhitespace }).first
        else {
            throw UpdateError.malformedSha("shasum output unparseable")
        }
        return String(token).lowercased()
    }

    /// Post a macOS notification via osascript. Used by the daily LaunchAgent
    /// (--check-only --notify) so users see updates without having to remember
    /// to run the command themselves. Best-effort: failures here are swallowed.
    private func postUpdateNotification(current: String, latest: String) {
        let title = "Bushel update available"
        let body = "\(current) -> \(latest). Run \\\"bushel update\\\" to apply."
        let script = "display notification \"\(body)\" with title \"\(title)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
        process.waitUntilExit()
    }

    @discardableResult
    private func runCommand(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed("\(tool) exited \(process.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }

    // MARK: - Entitlement verification (issue #20)

    /// Plist content embedded into the binary as the entitlement set.
    /// Duplicated in `.github/workflows/release.yml` and `scripts/install.sh`;
    /// the file is six lines and effectively a constant — keeping it inline
    /// per file is simpler than introducing a shared resource.
    static let entitlementsPlist: String = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.virtualization</key>
            <true/>
            <key>com.apple.security.hypervisor</key>
            <true/>
        </dict>
        </plist>
        """

    /// After a binary swap, verify the new binary carries the Virtualization
    /// entitlement; if not, ad-hoc re-sign it with the required keys.
    ///
    /// This is best-effort: failures are logged, not thrown. `bushel update`
    /// has already swapped the binary on disk by the time this runs, so
    /// bailing here would leave the user in a worse state than just noting
    /// the problem and letting them re-sign manually (the install.sh path
    /// will pick up the same logic on the next install).
    @discardableResult
    static func ensureEntitlement(binaryPath: URL) -> Bool {
        let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesignURL.path) else {
            print("warning: /usr/bin/codesign not available; skipping entitlement check.")
            print("         If '\(binaryPath.lastPathComponent) run' fails with a 'com.apple.security.virtualization'")
            print("         error, re-sign manually — see issue #20 for the recipe.")
            return false
        }

        if hasVirtualizationEntitlement(at: binaryPath, codesign: codesignURL) {
            print("Entitlement: already present on \(binaryPath.path).")
            return true
        }

        print("Entitlement missing on \(binaryPath.path); re-signing ad-hoc.")
        let plistURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bushel-entitlements-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: plistURL) }

        do {
            try entitlementsPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            print("warning: failed to write entitlements plist (\(error)); skipping resign.")
            return false
        }

        let sign = Process()
        sign.executableURL = codesignURL
        sign.arguments = ["--force", "--sign", "-", "--entitlements", plistURL.path, binaryPath.path]
        let signOut = Pipe()
        sign.standardOutput = signOut
        sign.standardError = signOut
        do {
            try sign.run()
        } catch {
            print("warning: codesign failed to launch (\(error)); skipping resign.")
            return false
        }
        sign.waitUntilExit()
        if sign.terminationStatus != 0 {
            let body = String(data: signOut.fileHandleForReading.readDataToEndOfFile(),
                              encoding: .utf8) ?? ""
            print("warning: codesign exited \(sign.terminationStatus): \(body.trimmingCharacters(in: .whitespacesAndNewlines))")
            return false
        }

        if hasVirtualizationEntitlement(at: binaryPath, codesign: codesignURL) {
            print("Entitlement: re-signed \(binaryPath.path).")
            return true
        }
        print("warning: re-sign succeeded but entitlement still missing on \(binaryPath.path).")
        return false
    }

    /// Run `codesign --display --entitlements -` and look for the
    /// 'com.apple.security.virtualization' key in the combined output.
    /// Returns false on any process failure (treated as "not present").
    private static func hasVirtualizationEntitlement(at binary: URL, codesign: URL) -> Bool {
        let process = Process()
        process.executableURL = codesign
        process.arguments = ["--display", "--entitlements", "-", binary.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("com.apple.security.virtualization")
    }
}

private enum UpdateError: Error, LocalizedError {
    case networkFailure(String)
    case shaMismatch(expected: String, actual: String)
    case malformedSha(String)
    case malformedTarball(String)
    case cannotResolveInstall(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .networkFailure(let m): return "Network: \(m)"
        case .shaMismatch(let e, let a): return "SHA-256 mismatch.\n  expected: \(e)\n  actual:   \(a)"
        case .malformedSha(let m): return "SHA sidecar: \(m)"
        case .malformedTarball(let m): return "Tarball: \(m)"
        case .cannotResolveInstall(let m): return "Install location: \(m)"
        case .commandFailed(let m): return "Command failed: \(m)"
        }
    }
}
