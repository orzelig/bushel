// bushel-bar — macOS menu bar item for bushel.
//
// Pure AppKit (no SwiftUI) so the binary stays small and start-up is fast.
// Polls the local bushel daemon's host_status HTTP endpoint every 5 seconds
// to surface running-VM count and daemon liveness in the menu bar. Provides
// quick actions for opening the lume-web-vm-manager dashboard, restarting
// the daemon, and quitting the bar app itself.
//
// Distributed alongside the bushel binary in the release tarball; install.sh
// optionally registers this as its own LaunchAgent
// (io.github.orzelig.bushel.menubar) when the user opts in via --menubar.

import AppKit
import Foundation

// MARK: - Configuration

private struct Config {
    static let daemonURL = URL(string: "http://127.0.0.1:7777")!
    // Built-in dashboard served by the bushel daemon itself (preferred).
    static let builtinDashboardURL = URL(string: "http://127.0.0.1:7777/")!
    // Legacy lume-web-vm-manager fallback (separate Python service).
    static let legacyDashboardURL = URL(string: "http://127.0.0.1:8080/")!
    static let pollInterval: TimeInterval = 5
    static let daemonLabel = "io.github.orzelig.bushel.daemon"
    static let daemonPlist = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/LaunchAgents/io.github.orzelig.bushel.daemon.plist")
    static let httpTimeout: TimeInterval = 2  // keep menu responsive
}

// MARK: - Daemon status snapshot

private struct DaemonStatus {
    var reachable: Bool
    var vmCount: Int
    var maxVMs: Int
    var availableSlots: Int
    var version: String

    static let unreachable = DaemonStatus(
        reachable: false, vmCount: 0, maxVMs: 0, availableSlots: 0, version: "?")
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var status = DaemonStatus.unreachable

    // Menu items we update on each poll. Holding refs avoids rebuilding the
    // menu every tick (which would close any open submenu under the user's
    // cursor).
    private var statusLineItem: NSMenuItem!
    private var openDashboardItem: NSMenuItem!
    private var toggleDaemonItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton()
        statusItem.menu = buildMenu()

        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            // Timer fires on main run loop; hop back into the actor explicitly
            // so Swift 6 region isolation is satisfied.
            Task { @MainActor in self?.refresh() }
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        // Two characters keep the bar slim. The system renders these as
        // monochrome glyphs that adapt to dark/light mode.
        button.title = "🌾"
        button.toolTip = "bushel"
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        statusLineItem = NSMenuItem(title: "Checking daemon…", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)

        menu.addItem(NSMenuItem.separator())

        openDashboardItem = NSMenuItem(
            title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        openDashboardItem.target = self
        menu.addItem(openDashboardItem)

        let openDaemonItem = NSMenuItem(
            title: "Open Daemon API…", action: #selector(openDaemonAPI), keyEquivalent: "")
        openDaemonItem.target = self
        menu.addItem(openDaemonItem)

        menu.addItem(NSMenuItem.separator())

        toggleDaemonItem = NSMenuItem(
            title: "Stop bushel daemon", action: #selector(toggleDaemon), keyEquivalent: "")
        toggleDaemonItem.target = self
        menu.addItem(toggleDaemonItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit bushel-bar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Polling

    private func refresh() {
        Task { [weak self] in
            let snapshot = await Self.fetchStatus()
            await self?.apply(status: snapshot)
        }
    }

    private func apply(status snapshot: DaemonStatus) {
        self.status = snapshot

        if let button = statusItem.button {
            // Glyph indicates daemon liveness without taking up much bar real
            // estate. 🌾 = running, ⚪ = unreachable.
            button.title = snapshot.reachable ? "🌾" : "⚪"
            if snapshot.reachable {
                button.toolTip = "bushel — \(snapshot.vmCount) running, \(snapshot.availableSlots) slot(s) free"
            } else {
                button.toolTip = "bushel daemon unreachable"
            }
        }

        if snapshot.reachable {
            statusLineItem.title =
                "Daemon: running (v\(snapshot.version)) · \(snapshot.vmCount)/\(snapshot.maxVMs) VMs"
            toggleDaemonItem.title = "Stop bushel daemon"
        } else {
            statusLineItem.title = "Daemon: not reachable on 127.0.0.1:7777"
            toggleDaemonItem.title = "Start bushel daemon"
        }
    }

    nonisolated private static func fetchStatus() async -> DaemonStatus {
        var request = URLRequest(url: Config.daemonURL.appendingPathComponent("/lume/host/status"))
        request.timeoutInterval = Config.httpTimeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .unreachable
            }
            return DaemonStatus(
                reachable: true,
                vmCount: (json["vm_count"] as? Int) ?? 0,
                maxVMs: (json["max_vms"] as? Int) ?? 0,
                availableSlots: (json["available_slots"] as? Int) ?? 0,
                version: (json["version"] as? String) ?? "?"
            )
        } catch {
            return .unreachable
        }
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        // Prefer the built-in dashboard served by the bushel daemon itself
        // (requires only that the daemon is running). Fall back to the
        // legacy lume-web-vm-manager URL on port 8080 if the daemon isn't
        // reachable but the legacy dashboard is. Show a friendly alert
        // only if neither is up.
        Task { [weak self] in
            if await Self.probe(url: Config.builtinDashboardURL) {
                await MainActor.run { NSWorkspace.shared.open(Config.builtinDashboardURL) }
                return
            }
            if await Self.probe(url: Config.legacyDashboardURL) {
                await MainActor.run { NSWorkspace.shared.open(Config.legacyDashboardURL) }
                return
            }
            guard let self = self else { return }
            self.showDashboardMissingAlertOnMain()
        }
    }

    private func showDashboardMissingAlertOnMain() {
        showDashboardMissingAlert()
    }

    nonisolated private static func probe(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = Config.httpTimeout
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }

    @objc private func openDaemonAPI() {
        NSWorkspace.shared.open(
            Config.daemonURL.appendingPathComponent("/lume/host/status"))
    }

    @objc private func toggleDaemon() {
        // Snapshot the intended action before the next poll changes state.
        let shouldStop = status.reachable
        // Spawn a detached task that doesn't capture `self` (to keep Swift 6
        // strict isolation happy), then hop back to MainActor for any UI work.
        Task.detached { [weak self] in
            let result = Self.runLaunchctl(action: shouldStop ? "unload" : "load")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Pass `result` and `self` across the actor boundary explicitly via
            // a Sendable-friendly call rather than capturing `self` in a closure
            // that's both task-isolated and main-actor-isolated.
            await Self.toggleDaemonFinish(self: self, result: result, didStop: shouldStop)
        }
    }

    nonisolated private static func toggleDaemonFinish(
        self appDelegate: AppDelegate?, result: (ok: Bool, output: String), didStop: Bool
    ) async {
        await MainActor.run {
            if !result.ok {
                showLaunchctlAlert(action: didStop ? "stop" : "start", message: result.output)
            }
            appDelegate?.refresh()
        }
    }

    @objc private func quit() {
        // Quits bushel-bar only; the bushel daemon itself is untouched.
        NSApp.terminate(nil)
    }

    // MARK: - launchctl helper

    nonisolated private static func runLaunchctl(action: String) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [action, Config.daemonPlist]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "Failed to launch launchctl: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, out)
    }
}

// MARK: - Alerts

@MainActor
private func showDashboardMissingAlert() {
    let alert = NSAlert()
    alert.messageText = "Dashboard not reachable"
    alert.informativeText =
        "Neither the built-in dashboard (http://127.0.0.1:7777/) nor the legacy lume-web-vm-manager " +
        "fallback (http://127.0.0.1:8080/) responded.\n\n" +
        "Start the bushel daemon with:\n\n" +
        "  bushel serve\n\n" +
        "or load the LaunchAgent that the installer set up. If the daemon is running and the dashboard " +
        "still won't load, check /tmp/bushel_daemon.error.log."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

@MainActor
private func showLaunchctlAlert(action: String, message: String) {
    let alert = NSAlert()
    alert.messageText = "Could not \(action) bushel daemon"
    alert.informativeText = message.isEmpty ? "launchctl returned a non-zero exit." : message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

// MARK: - Entrypoint

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement-equivalent: no Dock icon, no main menu bar takeover.
app.setActivationPolicy(.accessory)
app.run()
