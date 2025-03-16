import Foundation

struct Logger {
    typealias Metadata = [String: String]
    
    enum Level: String {
        case info
        case error
        case debug
    }
    
    static func info(_ message: String, metadata: Metadata = [:]) {
        log(.info, message, metadata)
    }
    
    static func error(_ message: String, metadata: Metadata = [:]) {
        log(.error, message, metadata)
    }
    
    static func debug(_ message: String, metadata: Metadata = [:]) {
        log(.debug, message, metadata)
    }
    
    private static func log(_ level: Level, _ message: String, _ metadata: Metadata) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let metadataString = metadata.isEmpty ? "" : " " + metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("[\(timestamp)] \(level.rawValue.uppercased()): \(message)\(metadataString)")
    }
}