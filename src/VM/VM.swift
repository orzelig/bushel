import Foundation

// MARK: - Support Types

/// Base context for virtual machine directory and configuration
struct VMDirContext {
    let dir: VMDirectory
    var config: VMConfig
    let home: Home
    let storage: String?

    func saveConfig() throws {
        try dir.saveConfig(config)
    }

    var name: String { dir.name }
    var initialized: Bool { dir.initialized() }
    var diskPath: Path { dir.diskPath }
    var nvramPath: Path { dir.nvramPath }

    func setDisk(_ size: UInt64) throws {
        try dir.setDisk(size)
    }

    func finalize(to name: String) throws {
        let vmDir = try home.getVMDirectory(name)
        try FileManager.default.moveItem(at: dir.dir.url, to: vmDir.dir.url)
    }
}

// MARK: - Base VM Class

/// Base class for virtual machine implementations
@MainActor
class VM {
    // MARK: - Properties

    var vmDirContext: VMDirContext

    @MainActor
    private var virtualizationService: VMVirtualizationService?
    private let vncService: VNCService
    internal let virtualizationServiceFactory:
        (VMVirtualizationServiceContext) throws -> VMVirtualizationService
    private let vncServiceFactory: (VMDirectory) -> VNCService

    // MARK: - Initialization

    init(
        vmDirContext: VMDirContext,
        virtualizationServiceFactory: @escaping (VMVirtualizationServiceContext) throws ->
            VMVirtualizationService = { try DarwinVirtualizationService(configuration: $0) },
        vncServiceFactory: @escaping (VMDirectory) -> VNCService = {
            DefaultVNCService(vmDirectory: $0)
        }
    ) {
        self.vmDirContext = vmDirContext
        self.virtualizationServiceFactory = virtualizationServiceFactory
        self.vncServiceFactory = vncServiceFactory

        // Initialize VNC service
        self.vncService = vncServiceFactory(vmDirContext.dir)
    }

    // MARK: - VM State Management

    private var isRunning: Bool {
        // First check if we have an IP address
        guard let ipAddress = DHCPLeaseParser.getIPAddress(forMAC: vmDirContext.config.macAddress!)
        else {
            return false
        }

        // Then check if it's reachable
        return NetworkUtils.isReachable(ipAddress: ipAddress)
    }

    var details: VMDetails {
        let isRunning: Bool = self.isRunning
        let vncUrl = isRunning ? getVNCUrl() : nil
        
        // Try to load shared directories from the session file
        var sharedDirs: [SharedDirectory]? = nil
        
        // Check if sessions file exists and load shared directories
        let sessionsPath = vmDirContext.dir.sessionsPath.path
        let fileExists = FileManager.default.fileExists(atPath: sessionsPath)
        
        do {
            if fileExists {
                let session = try vmDirContext.dir.loadSession()
                sharedDirs = session.sharedDirectories
            }
        } catch {
            // It's okay if we don't have a saved session
            Logger.error("Failed to load session data", metadata: ["name": vmDirContext.name, "error": "\(error)"])
        }

        return VMDetails(
            name: vmDirContext.name,
            os: getOSType(),
            cpuCount: vmDirContext.config.cpuCount ?? 0,
            memorySize: vmDirContext.config.memorySize ?? 0,
            diskSize: try! getDiskSize(),
            display: vmDirContext.config.display.string,
            status: isRunning ? "running" : "stopped",
            vncUrl: vncUrl,
            ipAddress: isRunning
                ? DHCPLeaseParser.getIPAddress(forMAC: vmDirContext.config.macAddress!) : nil,
            locationName: vmDirContext.storage ?? "default",
            sharedDirectories: sharedDirs
        )
    }

    // MARK: - VM Lifecycle Management

    func run(
        noDisplay: Bool, sharedDirectories: [SharedDirectory], mount: Path?, vncPort: Int = 0,
        recoveryMode: Bool = false, usbMassStoragePaths: [Path]? = nil
    ) async throws {
        guard vmDirContext.initialized else {
            throw VMError.notInitialized(vmDirContext.name)
        }

        guard let cpuCount = vmDirContext.config.cpuCount,
            let memorySize = vmDirContext.config.memorySize
        else {
            throw VMError.notInitialized(vmDirContext.name)
        }

        // Try to acquire lock on config file
        let fileHandle = try FileHandle(forWritingTo: vmDirContext.dir.configPath.url)
        guard flock(fileHandle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? fileHandle.close()
            throw VMError.alreadyRunning(vmDirContext.name)
        }

        // Keep track of shared directories for logging

        Logger.info(
            "Running VM with configuration",
            metadata: [
                "cpuCount": "\(cpuCount)",
                "memorySize": "\(memorySize)",
                "diskSize": "\(vmDirContext.config.diskSize ?? 0)",
                "macAddress": vmDirContext.config.macAddress ?? "none",
                "sharedDirectoryCount": "\(sharedDirectories.count)",
                "mount": mount?.path ?? "none",
                "vncPort": "\(vncPort)",
                "recoveryMode": "\(recoveryMode)",
                "usbMassStorageDeviceCount": "\(usbMassStoragePaths?.count ?? 0)",
            ])

        // Log disk paths and existence for debugging
        Logger.info(
            "VM disk paths",
            metadata: [
                "diskPath": vmDirContext.diskPath.path,
                "diskExists":
                    "\(FileManager.default.fileExists(atPath: vmDirContext.diskPath.path))",
                "nvramPath": vmDirContext.nvramPath.path,
                "nvramExists":
                    "\(FileManager.default.fileExists(atPath: vmDirContext.nvramPath.path))",
                "configPath": vmDirContext.dir.configPath.path,
                "configExists":
                    "\(FileManager.default.fileExists(atPath: vmDirContext.dir.configPath.path))",
                "locationName": vmDirContext.storage ?? "default",
            ])

        // Create and configure the VM
        do {
            let config = try createVMVirtualizationServiceContext(
                cpuCount: cpuCount,
                memorySize: memorySize,
                display: vmDirContext.config.display.string,
                sharedDirectories: sharedDirectories,
                mount: mount,
                recoveryMode: recoveryMode,
                usbMassStoragePaths: usbMassStoragePaths
            )
            virtualizationService = try virtualizationServiceFactory(config)

            let vncInfo = try await setupSession(noDisplay: noDisplay, port: vncPort, sharedDirectories: sharedDirectories)
            Logger.info("VNC info", metadata: ["vncInfo": vncInfo])

            // Start the VM
            guard let service = virtualizationService else {
                throw VMError.internalError("Virtualization service not initialized")
            }
            try await service.start()

            while true {
                try await Task.sleep(nanoseconds: UInt64(1e9))
            }
        } catch {
            Logger.error(
                "Failed to create/start VM",
                metadata: [
                    "error": "\(error)",
                    "errorType": "\(type(of: error))",
                ])
            virtualizationService = nil
            vncService.stop()
            // Release lock
            flock(fileHandle.fileDescriptor, LOCK_UN)
            try? fileHandle.close()
            throw error
        }
    }

    @MainActor
    func stop() async throws {
        guard vmDirContext.initialized else {
            throw VMError.notInitialized(vmDirContext.name)
        }

        Logger.info("Attempting to stop VM", metadata: ["name": vmDirContext.name])

        // If we have a virtualization service, try to stop it cleanly first
        if let service = virtualizationService {
            do {
                try await service.stop()
                virtualizationService = nil
                vncService.stop()
                Logger.info(
                    "VM stopped successfully via virtualization service",
                    metadata: ["name": vmDirContext.name])
                return
            } catch let error {
                Logger.error(
                    "Failed to stop VM via virtualization service, falling back to process termination",
                    metadata: [
                        "name": vmDirContext.name,
                        "error": "\(error)",
                    ])
                // Fall through to process termination
            }
        }

        // Try to open config file to get file descriptor - note that this matches with the serve process - so this is only for the command line
        let fileHandle = try? FileHandle(forReadingFrom: vmDirContext.dir.configPath.url)
        guard let fileHandle = fileHandle else {
            Logger.error(
                "Failed to open config file - VM not running", metadata: ["name": vmDirContext.name]
            )
            throw VMError.notRunning(vmDirContext.name)
        }

        // Get the PID of the process holding the lock using lsof command
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-F", "p", vmDirContext.dir.configPath.path]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe

        try task.run()
        task.waitUntilExit()

        let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        guard let outputString = String(data: outputData, encoding: .utf8),
            let pidString = outputString.split(separator: "\n").first?.dropFirst(),  // Drop the 'p' prefix
            let pid = pid_t(pidString)
        else {
            try? fileHandle.close()
            Logger.error(
                "Failed to find VM process - VM not running", metadata: ["name": vmDirContext.name])
            throw VMError.notRunning(vmDirContext.name)
        }

        // First try graceful shutdown with SIGINT
        if kill(pid, SIGINT) == 0 {
            Logger.info(
                "Sent SIGINT to VM process", metadata: ["name": vmDirContext.name, "pid": "\(pid)"])
        }

        // Wait for process to stop with timeout
        var attempts = 0
        while attempts < 10 {
            try await Task.sleep(nanoseconds: 1_000_000_000)

            // Check if process still exists
            if kill(pid, 0) != 0 {
                // Process is gone, do final cleanup
                virtualizationService = nil
                vncService.stop()
                try? fileHandle.close()

                Logger.info(
                    "VM stopped successfully via process termination",
                    metadata: ["name": vmDirContext.name])
                return
            }
            attempts += 1
        }

        // If graceful shutdown failed, force kill the process
        Logger.info(
            "Graceful shutdown failed, forcing termination", metadata: ["name": vmDirContext.name])
        if kill(pid, SIGKILL) == 0 {
            // Wait a moment for the process to be fully killed
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // Do final cleanup
            virtualizationService = nil
            vncService.stop()
            try? fileHandle.close()

            Logger.info("VM forcefully stopped", metadata: ["name": vmDirContext.name])
            return
        }

        // If we get here, something went very wrong
        try? fileHandle.close()
        Logger.error("Failed to stop VM", metadata: ["name": vmDirContext.name, "pid": "\(pid)"])
        throw VMError.internalError("Failed to stop VM process")
    }

    // MARK: - Resource Management

    func updateVMConfig(vmConfig: VMConfig) throws {
        vmDirContext.config = vmConfig
        try vmDirContext.saveConfig()
    }

    private func getDiskSize() throws -> DiskSize {
        let resourceValues = try vmDirContext.diskPath.url.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .totalFileSizeKey,
        ])

        guard let allocated = resourceValues.totalFileAllocatedSize,
            let total = resourceValues.totalFileSize
        else {
            throw VMConfigError.invalidDiskSize
        }

        return DiskSize(allocated: UInt64(allocated), total: UInt64(total))
    }

    func resizeDisk(_ newSize: UInt64) throws {
        let currentSize = try getDiskSize()

        guard newSize >= currentSize.total else {
            throw VMError.resizeTooSmall(current: currentSize.total, requested: newSize)
        }

        try setDiskSize(newSize)
    }

    func setCpuCount(_ newCpuCount: Int) throws {
        guard !isRunning else {
            throw VMError.alreadyRunning(vmDirContext.name)
        }
        vmDirContext.config.setCpuCount(newCpuCount)
        try vmDirContext.saveConfig()
    }

    func setMemorySize(_ newMemorySize: UInt64) throws {
        guard !isRunning else {
            throw VMError.alreadyRunning(vmDirContext.name)
        }
        vmDirContext.config.setMemorySize(newMemorySize)
        try vmDirContext.saveConfig()
    }

    func setDiskSize(_ newDiskSize: UInt64) throws {
        try vmDirContext.setDisk(newDiskSize)
        vmDirContext.config.setDiskSize(newDiskSize)
        try vmDirContext.saveConfig()
    }

    func setDisplay(_ newDisplay: String) throws {
        guard !isRunning else {
            throw VMError.alreadyRunning(vmDirContext.name)
        }
        guard let display: VMDisplayResolution = VMDisplayResolution(string: newDisplay) else {
            throw VMError.invalidDisplayResolution(newDisplay)
        }
        vmDirContext.config.setDisplay(display)
        try vmDirContext.saveConfig()
    }

    func setHardwareModel(_ newHardwareModel: Data) throws {
        guard !isRunning else {
            throw VMError.alreadyRunning(vmDirContext.name)
        }
        vmDirContext.config.setHardwareModel(newHardwareModel)
        try vmDirContext.saveConfig()
    }

    func setMachineIdentifier(_ newMachineIdentifier: Data) throws {
        guard !isRunning else {
            throw VMError.alreadyRunning(vmDirContext.name)
        }
        vmDirContext.config.setMachineIdentifier(newMachineIdentifier)
        try vmDirContext.saveConfig()
    }

    func setMacAddress(_ newMacAddress: String) throws {
        guard !isRunning else {
            throw VMError.alreadyRunning(vmDirContext.name)
        }
        vmDirContext.config.setMacAddress(newMacAddress)
        try vmDirContext.saveConfig()
    }

    // MARK: - VNC Management

    func getVNCUrl() -> String? {
        return vncService.url
    }

    /// Sets up the VNC service and returns the VNC URL
    private func startVNCService(port: Int = 0) async throws -> String {
        guard let service = virtualizationService else {
            throw VMError.internalError("Virtualization service not initialized")
        }

        try await vncService.start(port: port, virtualMachine: service.getVirtualMachine())

        guard let url = vncService.url else {
            throw VMError.vncNotConfigured
        }
        
        return url
    }
    
    /// Saves the session information including shared directories to disk
    private func saveSessionData(url: String, sharedDirectories: [SharedDirectory]) {
        do {
            let session = VNCSession(url: url, sharedDirectories: sharedDirectories.isEmpty ? nil : sharedDirectories)
            try vmDirContext.dir.saveSession(session)
            Logger.info("Saved VNC session with shared directories", 
                       metadata: [
                         "count": "\(sharedDirectories.count)", 
                         "dirs": "\(sharedDirectories.map { $0.hostPath }.joined(separator: ", "))",
                         "sessionsPath": "\(vmDirContext.dir.sessionsPath.path)"
                       ])
        } catch {
            Logger.error("Failed to save VNC session", metadata: ["error": "\(error)"])
        }
    }
    
    /// Main session setup method that handles VNC and persists session data
    private func setupSession(noDisplay: Bool, port: Int = 0, sharedDirectories: [SharedDirectory] = []) async throws -> String {
        // Start the VNC service and get the URL
        let url = try await startVNCService(port: port)
        
        // Save the session data
        saveSessionData(url: url, sharedDirectories: sharedDirectories)
        
        // Open the VNC client if needed
        if !noDisplay {
            Logger.info("Starting VNC session")
            try await vncService.openClient(url: url)
        }
        
        return url
    }

    // MARK: - Platform-specific Methods

    func getOSType() -> String {
        fatalError("Must be implemented by subclass")
    }

    func createVMVirtualizationServiceContext(
        cpuCount: Int,
        memorySize: UInt64,
        display: String,
        sharedDirectories: [SharedDirectory] = [],
        mount: Path? = nil,
        recoveryMode: Bool = false,
        usbMassStoragePaths: [Path]? = nil
    ) throws -> VMVirtualizationServiceContext {
        // This is a diagnostic log to track actual file paths on disk for debugging
        try validateDiskState()

        return VMVirtualizationServiceContext(
            cpuCount: cpuCount,
            memorySize: memorySize,
            display: display,
            sharedDirectories: sharedDirectories,
            mount: mount,
            hardwareModel: vmDirContext.config.hardwareModel,
            machineIdentifier: vmDirContext.config.machineIdentifier,
            macAddress: vmDirContext.config.macAddress!,
            diskPath: vmDirContext.diskPath,
            nvramPath: vmDirContext.nvramPath,
            recoveryMode: recoveryMode,
            usbMassStoragePaths: usbMassStoragePaths
        )
    }

    /// Validates the disk state to help diagnose storage attachment issues
    private func validateDiskState() throws {
        // Check disk image state
        let diskPath = vmDirContext.diskPath.path
        let diskExists = FileManager.default.fileExists(atPath: diskPath)
        var diskSize: UInt64 = 0
        var diskPermissions = ""

        if diskExists {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: diskPath) {
                diskSize = attrs[.size] as? UInt64 ?? 0
                let posixPerms = attrs[.posixPermissions] as? Int ?? 0
                diskPermissions = String(format: "%o", posixPerms)
            }
        }

        // Check disk container directory permissions
        let diskDir = (diskPath as NSString).deletingLastPathComponent
        let dirPerms =
            try? FileManager.default.attributesOfItem(atPath: diskDir)[.posixPermissions] as? Int
            ?? 0
        let dirPermsString = dirPerms != nil ? String(format: "%o", dirPerms!) : "unknown"

        // Log detailed diagnostics
        Logger.info(
            "Validating VM disk state",
            metadata: [
                "diskPath": diskPath,
                "diskExists": "\(diskExists)",
                "diskSize":
                    "\(ByteCountFormatter.string(fromByteCount: Int64(diskSize), countStyle: .file))",
                "diskPermissions": diskPermissions,
                "dirPermissions": dirPermsString,
                "locationName": vmDirContext.storage ?? "default",
            ])

        if !diskExists {
            Logger.error("VM disk image does not exist", metadata: ["diskPath": diskPath])
        } else if diskSize == 0 {
            Logger.error("VM disk image exists but has zero size", metadata: ["diskPath": diskPath])
        }
    }

    func setup(
        ipswPath: String,
        cpuCount: Int,
        memorySize: UInt64,
        diskSize: UInt64,
        display: String
    ) async throws {
        fatalError("Must be implemented by subclass")
    }

    // MARK: - Finalization

    /// Post-installation step to move the VM directory to the home directory
    func finalize(to name: String, home: Home, storage: String? = nil) throws {
        let vmDir = try home.getVMDirectory(name, storage: storage)
        try FileManager.default.moveItem(at: vmDirContext.dir.dir.url, to: vmDir.dir.url)
    }

    // Method to run VM with additional USB mass storage devices
    func runWithUSBStorage(
        noDisplay: Bool, sharedDirectories: [SharedDirectory], mount: Path?, vncPort: Int = 0,
        recoveryMode: Bool = false, usbImagePaths: [Path]
    ) async throws {
        guard vmDirContext.initialized else {
            throw VMError.notInitialized(vmDirContext.name)
        }

        guard let cpuCount = vmDirContext.config.cpuCount,
            let memorySize = vmDirContext.config.memorySize
        else {
            throw VMError.notInitialized(vmDirContext.name)
        }

        // Try to acquire lock on config file
        let fileHandle = try FileHandle(forWritingTo: vmDirContext.dir.configPath.url)
        guard flock(fileHandle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? fileHandle.close()
            throw VMError.alreadyRunning(vmDirContext.name)
        }

        Logger.info(
            "Running VM with USB storage devices",
            metadata: [
                "cpuCount": "\(cpuCount)",
                "memorySize": "\(memorySize)",
                "diskSize": "\(vmDirContext.config.diskSize ?? 0)",
                "usbImageCount": "\(usbImagePaths.count)",
                "recoveryMode": "\(recoveryMode)",
            ])

        // Create and configure the VM
        do {
            let config = try createVMVirtualizationServiceContext(
                cpuCount: cpuCount,
                memorySize: memorySize,
                display: vmDirContext.config.display.string,
                sharedDirectories: sharedDirectories,
                mount: mount,
                recoveryMode: recoveryMode,
                usbMassStoragePaths: usbImagePaths
            )
            virtualizationService = try virtualizationServiceFactory(config)

            let vncInfo = try await setupSession(noDisplay: noDisplay, port: vncPort, sharedDirectories: sharedDirectories)
            Logger.info("VNC info", metadata: ["vncInfo": vncInfo])

            // Start the VM
            guard let service = virtualizationService else {
                throw VMError.internalError("Virtualization service not initialized")
            }
            try await service.start()

            while true {
                try await Task.sleep(nanoseconds: UInt64(1e9))
            }
        } catch {
            Logger.error(
                "Failed to create/start VM with USB storage",
                metadata: [
                    "error": "\(error)",
                    "errorType": "\(type(of: error))",
                ])
            virtualizationService = nil
            vncService.stop()
            // Release lock
            flock(fileHandle.fileDescriptor, LOCK_UN)
            try? fileHandle.close()
            throw error
        }
    }
}
