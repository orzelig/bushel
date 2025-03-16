import Foundation

// MARK: - VMDirectory

/// Manages a virtual machine's directory structure and files
/// Responsible for:
/// - Managing VM configuration files
/// - Handling disk operations
/// - Managing VM state and locking
/// - Providing access to VM-related paths
struct VMDirectory {
    // MARK: - Constants
    
    private enum FileNames {
        static let nvram = "nvram.bin"
        static let disk = "disk.img"
        static let config = "config.json"
        static let sessions = "sessions.json"
    }
    
    // MARK: - Properties
    
    let dir: Path
    let nvramPath: Path
    let diskPath: Path
    let configPath: Path
    let sessionsPath: Path
    
    private let fileManager: FileManager
    
    /// The name of the VM directory
    var name: String { dir.name }
    
    // MARK: - Initialization
    
    /// Creates a new VMDirectory instance
    /// - Parameters:
    ///   - dir: The base directory path for the VM
    ///   - fileManager: FileManager instance to use for file operations
    init(_ dir: Path, fileManager: FileManager = .default) {
        self.dir = dir
        self.fileManager = fileManager
        self.nvramPath = dir.file(FileNames.nvram)
        self.diskPath = dir.file(FileNames.disk)
        self.configPath = dir.file(FileNames.config)
        self.sessionsPath = dir.file(FileNames.sessions)
    }
}

// MARK: - VM State Management

extension VMDirectory {
    /// Checks if the VM directory is fully initialized with all required files
    func initialized() -> Bool {
        configPath.exists() && diskPath.exists() && nvramPath.exists()
    }

    /// Checks if the VM directory exists
    func exists() -> Bool {
        dir.exists()
    }
}

// MARK: - Disk Management

extension VMDirectory {
    /// Resizes the VM's disk to the specified size
    /// - Parameter size: The new size in bytes
    /// - Throws: VMDirectoryError if the disk operation fails
    func setDisk(_ size: UInt64) throws {
        do {
            if !diskPath.exists() {
                guard fileManager.createFile(atPath: diskPath.path, contents: nil) else {
                    throw VMDirectoryError.fileCreationFailed(diskPath.path)
                }
            }
            
            let handle = try FileHandle(forWritingTo: diskPath.url)
            defer { try? handle.close() }
            
            try handle.truncate(atOffset: size)
        } catch {
        }
    }
}

// MARK: - Configuration Management

extension VMDirectory {
    /// Saves the VM configuration to disk
    /// - Parameter config: The configuration to save
    /// - Throws: VMDirectoryError if the save operation fails
    func saveConfig(_ config: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let data = try encoder.encode(config)
            guard fileManager.createFile(atPath: configPath.path, contents: data) else {
                throw VMDirectoryError.fileCreationFailed(configPath.path)
            }
        } catch {
            throw VMDirectoryError.invalidConfigData
        }
    }

    /// Loads the VM configuration from disk
    /// - Returns: The loaded configuration
    /// - Throws: VMDirectoryError if the load operation fails
    func loadConfig() throws -> VMConfig {
        guard let data = fileManager.contents(atPath: configPath.path) else {
            throw VMDirectoryError.configNotFound
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(VMConfig.self, from: data)
        } catch {
            throw VMDirectoryError.invalidConfigData
        }
    }
}

// MARK: - VNC Session Management

struct VNCSession: Codable {
    let url: String
}

extension VMDirectory {
    /// Saves VNC session information to disk
    /// - Parameter session: The VNC session to save
    /// - Throws: VMDirectoryError if the save operation fails
    func saveSession(_ session: VNCSession) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let data = try encoder.encode(session)
            guard fileManager.createFile(atPath: sessionsPath.path, contents: data) else {
                throw VMDirectoryError.fileCreationFailed(sessionsPath.path)
            }
        } catch {
            throw VMDirectoryError.invalidSessionData
        }
    }
    
    /// Loads the VNC session information from disk
    /// - Returns: The loaded VNC session
    /// - Throws: VMDirectoryError if the load operation fails
    func loadSession() throws -> VNCSession {
        guard let data = fileManager.contents(atPath: sessionsPath.path) else {
            throw VMDirectoryError.sessionNotFound
        }
        
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(VNCSession.self, from: data)
        } catch {
            throw VMDirectoryError.invalidSessionData
        }
    }
    
    /// Removes the VNC session information from disk
    func clearSession() {
        try? fileManager.removeItem(atPath: sessionsPath.path)
    }
}

// MARK: - CustomStringConvertible
extension VMDirectory: CustomStringConvertible {
    var description: String {
        "VMDirectory(path: \(dir.path))"
    }
}

extension VMDirectory {
    func delete() throws {
        try fileManager.removeItem(atPath: dir.path)
    }
}
