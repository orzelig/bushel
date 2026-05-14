import ArgumentParser
import Foundation

@main
struct Lume: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "bushel",
            abstract: "A lightweight CLI and local API server to build, run and manage macOS VMs.",
            version: Version.current,
            subcommands: CommandRegistry.allCommands,
            helpNames: .long
        )
    }
}

// MARK: - Version Management
extension Lume {
    enum Version {
        // NOTE: Source of truth for `bushel --version`. Must be kept in sync
        // with the VERSION file at repo root. A build-time injection step
        // would deduplicate this; deferred for now.
        static let current: String = "0.4.0-bushel.20"
    }
}

// MARK: - ASCII Art Banner
extension Lume {
    static let banner = """
    \u{001B}[34m  ⠀⣀⣀⡀⠀⠀⠀⠀⢀⣀⣀⣀⡀⠘⠋⢉⠙⣷⠀⠀ ⠀
     ⠀⠀⢀⣴⣿⡿⠋⣉⠁⣠⣾⣿⣿⣿⣿⡿⠿⣦⡈⠀⣿⡇⠃⠀
     ⠀⠀⠀⣽⣿⣧⠀⠃⢰⣿⣿⡏⠙⣿⠿⢧⣀⣼⣷⠀⡿⠃⠀⠀
     ⠀⠀⠀⠉⣿⣿⣦⠀⢿⣿⣿⣷⣾⡏⠀⠀⢹⣿⣿⠀⠀⠀⠀⠀⠀
     ⠀⠀⠀⠀⠀⠉⠛⠁⠈⠿⣿⣿⣿⣷⣄⣠⡼⠟⠁\u{001B}[0m\u{001B}[1m  bushel v\(Version.current)\u{001B}[0m
    \u{001B}[34m           macOS VM CLI and server\u{001B}[0m
    """

    static func printBanner() {
        print(banner)
        print()
    }

    static func shouldShowBanner() -> Bool {
        let args = CommandLine.arguments.dropFirst()
        // Show banner when: no args, --help, -h, help, or just the root command
        if args.isEmpty {
            return true
        }
        if args.contains("--help") || args.contains("-h") {
            return true
        }
        // Check if first arg is "help" (e.g., "bushel help")
        if args.first == "help" && args.count == 1 {
            return true
        }
        return false
    }
}

// MARK: - Command Execution
extension Lume {
    public static func main() async {
        // Record installation event on first run (sent regardless of telemetry opt-out)
        TelemetryClient.shared.recordInstallation()

        // Print banner when showing help
        if shouldShowBanner() {
            printBanner()
        }

        do {
            try await executeCommand()
        } catch {
            exit(withError: error)
        }
    }

    private static func executeCommand() async throws {
        var command = try parseAsRoot()

        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    }
}