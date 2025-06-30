import Foundation
import Dynamic
import Virtualization

/// Protocol defining the interface for VNC server operations
@MainActor
protocol VNCService {
    var url: String? { get }
    func start(port: Int, virtualMachine: Any?) async throws
    func stop()
    func openClient(url: String) async throws
}

/// Default implementation of VNCService
@MainActor
final class DefaultVNCService: VNCService {
    private var vncServer: Any?
    private let vmDirectory: VMDirectory
    
    init(vmDirectory: VMDirectory) {
        self.vmDirectory = vmDirectory
    }
    
    var url: String? {
        get {
            return try? vmDirectory.loadSession().url
        }
    }
    
    func start(port: Int, virtualMachine: Any?) async throws {
        let password = Array(PassphraseGenerator().prefix(4)).joined(separator: "-")
        let securityConfiguration = Dynamic._VZVNCAuthenticationSecurityConfiguration(password: password)
        
        // Create VNC server with specified port
        let server = Dynamic._VZVNCServer(port: port, queue: DispatchQueue.main,
                                      securityConfiguration: securityConfiguration)
        
        if let vm = virtualMachine as? VZVirtualMachine {
            server.virtualMachine = vm
        }
        server.start()
        
        vncServer = server
        
        // Wait for port to be assigned (both for auto-assign and specific port)
        var attempts = 0
        let maxAttempts = 20  // 1 second total wait time
        while true {
            if let assignedPort: UInt16 = server.port.asUInt16 {
                // If we got a non-zero port, check if it matches our request
                if assignedPort != 0 {
                    // For specific port requests, verify we got the requested port
                    if port != 0 && Int(assignedPort) != port {
                        throw VMError.vncPortBindingFailed(requested: port, actual: Int(assignedPort))
                    }
                    
                    // Get the local IP address for the URL - prefer IPv4
                    let hostIP = try getLocalIPAddress() ?? "127.0.0.1"
                    let url = "vnc://:\(password)@127.0.0.1:\(assignedPort)"  // Use localhost for local connections
                    let externalUrl = "vnc://:\(password)@\(hostIP):\(assignedPort)"  // External URL for remote connections
                    
                    Logger.info("VNC server started", metadata: [
                        "local": url,
                        "external": externalUrl
                    ])
                    
                    // Save session information with local URL for the client
                    let session = VNCSession(url: url)
                    try vmDirectory.saveSession(session)
                    break
                }
            }
            
            attempts += 1
            if attempts >= maxAttempts {
                // If we've timed out and we requested a specific port, it likely means binding failed
                vncServer = nil
                if port != 0 {
                    throw VMError.vncPortBindingFailed(requested: port, actual: -1)
                }
                throw VMError.internalError("Timeout waiting for VNC server to start")
            }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms delay between checks
        }
    }
    
    // Modified to prefer IPv4 addresses
    private func getLocalIPAddress() throws -> String? {
        var address: String?
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            let interface = ptr?.pointee
            let family = interface?.ifa_addr.pointee.sa_family
            
            // Only look for IPv4 addresses
            if family == UInt8(AF_INET) {
                let name = String(cString: (interface?.ifa_name)!)
                if name == "en0" { // Primary interface
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface?.ifa_addr,
                              socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                              &hostname,
                              socklen_t(hostname.count),
                              nil,
                              0,
                              NI_NUMERICHOST)
                    address = String(cString: hostname, encoding: .utf8)
                    break
                }
            }
        }
        
        return address
    }
    
    func stop() {
        if let server = vncServer as? Dynamic {
            server.stop()
        }
        vncServer = nil
        vmDirectory.clearSession()
    }
    
    func openClient(url: String) async throws {
        let processRunner = DefaultProcessRunner()
        try processRunner.run(executable: "/usr/bin/open", arguments: [url])
    }
} 