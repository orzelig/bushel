import Foundation

enum NetworkUtils {
    /// Checks if an IP address is reachable by sending a ping
    /// - Parameter ipAddress: The IP address to check
    /// - Returns: true if the IP is reachable, false otherwise
    static func isReachable(ipAddress: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-t", "1", ipAddress]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
} 