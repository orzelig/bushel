import ArgumentParser
import Foundation

/// Wires bushel into Claude clients (Desktop, Code) as an MCP server.
///
/// The goal is one command to go from "bushel installed" to "Claude can drive it,"
/// with no JSON editing on the user's part. Idempotent — re-running is a safe no-op
/// when the config is already correct.
struct ClaudeSetup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-setup",
        abstract: "Wire bushel into Claude Desktop and Claude Code as an MCP server.",
        discussion: """
            Detects installed Claude clients and adds an MCP server entry pointing at
            this bushel binary. After running, ask Claude: "Start using bushel."

            Claude Desktop config: ~/Library/Application Support/Claude/claude_desktop_config.json
            Claude Code: registers via `claude mcp add` if the CLI is on PATH.
            """
    )

    @Flag(name: .long, help: "Show what would change without writing files.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Print the Claude Desktop config snippet to stdout instead of editing files.")
    var printOnly: Bool = false

    @Option(name: .long, help: "Override the bushel binary path written into the config.")
    var bushelPath: String?

    func run() throws {
        let resolvedPath = try resolveBushelPath()
        print("bushel binary: \(resolvedPath)")
        print("")

        if printOnly {
            try printSnippet(bushelPath: resolvedPath)
            return
        }

        var didAnything = false
        didAnything = try setupClaudeDesktop(bushelPath: resolvedPath) || didAnything
        didAnything = try setupClaudeCode(bushelPath: resolvedPath) || didAnything

        print("")
        if didAnything {
            print("Done. If a Claude client is already running, restart it to pick up the new MCP server.")
            print("Then ask Claude: \"Start using bushel.\"")
        } else {
            print("No Claude client detected.")
            print("Install Claude Desktop (https://claude.ai/download) or Claude Code,")
            print("then re-run: bushel claude-setup")
        }
    }

    // MARK: - Resolve bushel binary path

    private func resolveBushelPath() throws -> String {
        if let override = bushelPath { return override }
        // Bundle.main.executablePath gives the running process's binary location, which
        // is what we want — the same binary the user just invoked.
        if let path = Bundle.main.executablePath { return path }
        throw ValidationError("Could not resolve bushel binary path. Pass --bushel-path explicitly.")
    }

    // MARK: - Claude Desktop

    /// Returns true if a change was made or would be made (in dry-run).
    private func setupClaudeDesktop(bushelPath: String) throws -> Bool {
        let configPath = NSString(string: "~/Library/Application Support/Claude/claude_desktop_config.json")
            .expandingTildeInPath
        let configURL = URL(fileURLWithPath: configPath)
        let claudeAppDir = configURL.deletingLastPathComponent().path

        // Heuristic: if the Claude config dir doesn't exist, Claude Desktop has never
        // run on this machine. Skip rather than create a stub config the user didn't ask for.
        guard FileManager.default.fileExists(atPath: claudeAppDir) else {
            print("Claude Desktop: not detected (no \(claudeAppDir)). Skipping.")
            return false
        }

        var json: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configPath) {
            let data = try Data(contentsOf: configURL)
            if !data.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    print("Claude Desktop: \(configPath) exists but isn't a JSON object. Refusing to overwrite.")
                    print("  Edit it by hand and add the bushel server, or run with --print-only to see the snippet.")
                    return false
                }
                json = parsed
            }
        }

        var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
        let desired: [String: Any] = ["command": bushelPath, "args": ["serve", "--mcp"]]

        if let existing = servers["bushel"] as? [String: Any], dictsEqual(existing, desired) {
            print("Claude Desktop: bushel already registered (\(configPath)). No change.")
            return false
        }

        servers["bushel"] = desired
        json["mcpServers"] = servers

        if dryRun {
            print("Claude Desktop: would update \(configPath) (dry-run).")
            return true
        }

        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: configURL, options: .atomic)
        print("Claude Desktop: updated \(configPath).")
        return true
    }

    // MARK: - Claude Code

    private func setupClaudeCode(bushelPath: String) throws -> Bool {
        let claudePath = which("claude")
        guard let claudePath else {
            print("Claude Code: `claude` CLI not on PATH. Skipping.")
            return false
        }

        if dryRun {
            print("Claude Code: would run `\(claudePath) mcp add bushel \(bushelPath) serve --mcp` (dry-run).")
            return true
        }

        // `claude mcp add` is idempotent-ish: if the server name already exists with the
        // same command, it's a no-op; if it's different, it errors. We `remove` first to
        // make this fully idempotent regardless of prior state.
        _ = runProcess(claudePath, args: ["mcp", "remove", "bushel"], captureOutput: true)
        let result = runProcess(claudePath, args: ["mcp", "add", "bushel", bushelPath, "serve", "--mcp"], captureOutput: true)
        if result.exitCode == 0 {
            print("Claude Code: registered bushel via \(claudePath) mcp add.")
            return true
        } else {
            print("Claude Code: `claude mcp add` failed (exit \(result.exitCode)).")
            if !result.output.isEmpty { print("  \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            return false
        }
    }

    // MARK: - Print-only mode

    private func printSnippet(bushelPath: String) throws {
        let snippet: [String: Any] = [
            "mcpServers": [
                "bushel": ["command": bushelPath, "args": ["serve", "--mcp"]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: snippet, options: [.prettyPrinted, .sortedKeys])
        print("Claude Desktop config snippet — merge into ~/Library/Application Support/Claude/claude_desktop_config.json:")
        print("")
        print(String(data: data, encoding: .utf8) ?? "{}")
        print("")
        print("Claude Code: claude mcp add bushel \(bushelPath) serve --mcp")
    }

    // MARK: - Process helpers

    private func which(_ tool: String) -> String? {
        let result = runProcess("/usr/bin/which", args: [tool], captureOutput: true)
        guard result.exitCode == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private struct ProcessResult { let exitCode: Int32; let output: String }

    private func runProcess(_ path: String, args: [String], captureOutput: Bool) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        if captureOutput {
            process.standardOutput = pipe
            process.standardError = pipe
        }
        do {
            try process.run()
            process.waitUntilExit()
            let data = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
            return ProcessResult(
                exitCode: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return ProcessResult(exitCode: -1, output: error.localizedDescription)
        }
    }

    // MARK: - JSON dict comparison

    private func dictsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let aData = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let bData = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        else { return false }
        return aData == bData
    }
}
