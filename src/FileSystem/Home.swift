import Foundation

/// Manages the application's home directory and virtual machine directories.
/// Responsible for creating, accessing, and validating the application's directory structure.
final class Home {
    // MARK: - Constants
    
    private enum Constants {
        static let defaultDirectoryName = ".lume"
        static let homeDirPath = "~/\(defaultDirectoryName)"
    }
    
    // MARK: - Properties
    
    let homeDir: Path
    private let fileManager: FileManager
    
    // MARK: - Initialization
    
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.homeDir = Path(Constants.homeDirPath)
    }
    
    // MARK: - VM Directory Management
    
    /// Creates a temporary VM directory with a unique identifier
    /// - Returns: A VMDirectory instance representing the created directory
    /// - Throws: HomeError if directory creation fails
    func createTempVMDirectory() throws -> VMDirectory {
        let uuid = UUID().uuidString
        let tempDir = homeDir.directory(uuid)
        
        Logger.info("Creating temporary directory", metadata: ["path": tempDir.path])
        
        do {
            try createDirectory(at: tempDir.url)
            return VMDirectory(tempDir)
        } catch {
            throw HomeError.directoryCreationFailed(path: tempDir.path)
        }
    }
    
    /// Returns a VMDirectory instance for the given name
    /// - Parameter name: Name of the VM directory
    /// - Returns: A VMDirectory instance
    func getVMDirectory(_ name: String) -> VMDirectory {
        VMDirectory(homeDir.directory(name))
    }
    
    /// Returns all initialized VM directories
    /// - Returns: An array of VMDirectory instances
    /// - Throws: HomeError if directory access is denied
    func getAllVMDirectories() throws -> [VMDirectory] {
        guard homeDir.exists() else { return [] }
        
        do {
            let allFolders = try fileManager.contentsOfDirectory(
                at: homeDir.url,
                includingPropertiesForKeys: nil
            )
            let folders = allFolders
                .compactMap { url in
                    let sanitizedName = sanitizeFileName(url.lastPathComponent)
                    let dir = getVMDirectory(sanitizedName)
                    let dir1 = dir.initialized() ? dir : nil
                    return dir1
                }
            return folders
        } catch {
            throw HomeError.directoryAccessDenied(path: homeDir.path)
        }
    }
    
    /// Copies a VM directory to a new location with a new name
    /// - Parameters:
    ///   - sourceName: Name of the source VM
    ///   - destName: Name for the destination VM
    /// - Throws: HomeError if the copy operation fails
    func copyVMDirectory(from sourceName: String, to destName: String) throws {
        let sourceDir = getVMDirectory(sourceName)
        let destDir = getVMDirectory(destName)
        
        if destDir.initialized() {
            throw HomeError.directoryAlreadyExists(path: destDir.dir.path)
        }
        
        do {
            try fileManager.copyItem(atPath: sourceDir.dir.path, toPath: destDir.dir.path)
        } catch {
            throw HomeError.directoryCreationFailed(path: destDir.dir.path)
        }
    }
    
    // MARK: - Directory Validation
    
    /// Validates and ensures the existence of the home directory
    /// - Throws: HomeError if validation fails or directory creation fails
    func validateHomeDirectory() throws {
        if !homeDir.exists() {
            try createHomeDirectory()
            return
        }
        
        guard isValidDirectory(at: homeDir.path) else {
            throw HomeError.invalidHomeDirectory
        }
    }
    
    // MARK: - Private Helpers
    
    private func createHomeDirectory() throws {
        do {
            try createDirectory(at: homeDir.url)
        } catch {
            throw HomeError.directoryCreationFailed(path: homeDir.path)
        }
    }
    
    private func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
    
    private func isValidDirectory(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) 
            && isDirectory.boolValue 
            && Path(path).writable()
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        // Only decode percent encoding (e.g., %20 for spaces)
        return name.removingPercentEncoding ?? name
    }
}

// MARK: - Home + CustomStringConvertible

extension Home: CustomStringConvertible {
    var description: String {
        "Home(path: \(homeDir.path))"
    }
}