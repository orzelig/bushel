import ArgumentParser
import Foundation
import Swift

struct Layer: Codable, Equatable {
    let mediaType: String
    let digest: String
    let size: Int
}

struct Manifest: Codable {
    let layers: [Layer]
    let config: Layer?
    let mediaType: String
    let schemaVersion: Int
}

struct RepositoryTag: Codable {
    let name: String
    let tags: [String]
}

struct RepositoryList: Codable {
    let repositories: [String]
}

struct RepositoryTags: Codable {
    let name: String
    let tags: [String]
}

struct CachedImage {
    let repository: String
    let imageId: String
    let manifestId: String
}

struct ImageMetadata: Codable {
    let image: String
    let manifestId: String
    let timestamp: Date
}

actor ProgressTracker {
    private var totalBytes: Int64 = 0
    private var downloadedBytes: Int64 = 0
    private var progressLogger = ProgressLogger(threshold: 0.01)
    private var totalFiles: Int = 0
    private var completedFiles: Int = 0
    
    func setTotal(_ total: Int64, files: Int) {
        totalBytes = total
        totalFiles = files
    }
    
    func addProgress(_ bytes: Int64) {
        downloadedBytes += bytes
        let progress = Double(downloadedBytes) / Double(totalBytes)
        progressLogger.logProgress(current: progress, context: "Downloading Image")
    }
}

actor TaskCounter {
    private var count: Int = 0
    
    func increment() { count += 1 }
    func decrement() { count -= 1 }
    func current() -> Int { count }
}

class ImageContainerRegistry: @unchecked Sendable {
    private let registry: String
    private let organization: String
    private let progress = ProgressTracker()
    private let cacheDirectory: URL
    private let downloadLock = NSLock()
    private var activeDownloads: [String] = []

    init(registry: String, organization: String) {
        self.registry = registry
        self.organization = organization
        
        // Setup cache directory in user's home
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cacheDirectory = home.appendingPathComponent(".lume/cache/ghcr")
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Create organization directory
        let orgDir = cacheDirectory.appendingPathComponent(organization)
        try? FileManager.default.createDirectory(at: orgDir, withIntermediateDirectories: true)
    }
    
    private func getManifestIdentifier(_ manifest: Manifest, manifestDigest: String) -> String {
        // Use the manifest's own digest as the identifier
        return manifestDigest.replacingOccurrences(of: ":", with: "_")
    }
    
    private func getShortImageId(_ digest: String) -> String {
        // Take first 12 characters of the digest after removing the "sha256:" prefix
        let id = digest.replacingOccurrences(of: "sha256:", with: "")
        return String(id.prefix(12))
    }
    
    private func getImageCacheDirectory(manifestId: String) -> URL {
        return cacheDirectory
            .appendingPathComponent(organization)
            .appendingPathComponent(manifestId)
    }
    
    private func getCachedManifestPath(manifestId: String) -> URL {
        return getImageCacheDirectory(manifestId: manifestId).appendingPathComponent("manifest.json")
    }
    
    private func getCachedLayerPath(manifestId: String, digest: String) -> URL {
        return getImageCacheDirectory(manifestId: manifestId).appendingPathComponent(digest.replacingOccurrences(of: ":", with: "_"))
    }
    
    private func setupImageCache(manifestId: String) throws {
        let cacheDir = getImageCacheDirectory(manifestId: manifestId)
        // Remove existing cache if it exists
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.removeItem(at: cacheDir)
            // Ensure it's completely removed
            while FileManager.default.fileExists(atPath: cacheDir.path) {
                try? FileManager.default.removeItem(at: cacheDir)
            }
        }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
    
    private func loadCachedManifest(manifestId: String) -> Manifest? {
        let manifestPath = getCachedManifestPath(manifestId: manifestId)
        guard let data = try? Data(contentsOf: manifestPath) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
    
    private func validateCache(manifest: Manifest, manifestId: String) -> Bool {
        // First check if manifest exists and matches
        guard let cachedManifest = loadCachedManifest(manifestId: manifestId),
              cachedManifest.layers == manifest.layers else {
            return false
        }
        
        // Then verify all layer files exist
        for layer in manifest.layers {
            let cachedLayer = getCachedLayerPath(manifestId: manifestId, digest: layer.digest)
            if !FileManager.default.fileExists(atPath: cachedLayer.path) {
                return false
            }
        }
        
        return true
    }
    
    private func saveManifest(_ manifest: Manifest, manifestId: String) throws {
        let manifestPath = getCachedManifestPath(manifestId: manifestId)
        try JSONEncoder().encode(manifest).write(to: manifestPath)
    }
    
    private func isDownloading(_ digest: String) -> Bool {
        downloadLock.lock()
        defer { downloadLock.unlock() }
        return activeDownloads.contains(digest)
    }

    private func markDownloadStarted(_ digest: String) {
        downloadLock.lock()
        if !activeDownloads.contains(digest) {
            activeDownloads.append(digest)
        }
        downloadLock.unlock()
    }

    private func markDownloadComplete(_ digest: String) {
        downloadLock.lock()
        activeDownloads.removeAll { $0 == digest }
        downloadLock.unlock()
    }

    private func waitForExistingDownload(_ digest: String, cachedLayer: URL) async throws {
        while isDownloading(digest) {
            try await Task.sleep(nanoseconds: 1_000_000_000) // Sleep for 1 second
            if FileManager.default.fileExists(atPath: cachedLayer.path) {
                return // File is now available
            }
        }
    }
    
    private func saveImageMetadata(image: String, manifestId: String) throws {
        let metadataPath = getImageCacheDirectory(manifestId: manifestId).appendingPathComponent("metadata.json")
        let metadata = ImageMetadata(
            image: image,
            manifestId: manifestId,
            timestamp: Date()
        )
        try JSONEncoder().encode(metadata).write(to: metadataPath)
    }
    
    private func cleanupOldVersions(currentManifestId: String, image: String) throws {
        Logger.info("Checking for old versions of image to clean up", metadata: [
            "image": image,
            "current_manifest_id": currentManifestId
        ])
        
        let orgDir = cacheDirectory.appendingPathComponent(organization)
        guard FileManager.default.fileExists(atPath: orgDir.path) else { return }
        
        let contents = try FileManager.default.contentsOfDirectory(atPath: orgDir.path)
        for item in contents {
            if item == currentManifestId { continue }
            
            let itemPath = orgDir.appendingPathComponent(item)
            let metadataPath = itemPath.appendingPathComponent("metadata.json")
            
            if let metadataData = try? Data(contentsOf: metadataPath),
               let metadata = try? JSONDecoder().decode(ImageMetadata.self, from: metadataData) {
                if metadata.image == image {
                    try FileManager.default.removeItem(at: itemPath)
                    Logger.info("Removed old version of image", metadata: [
                        "image": image,
                        "old_manifest_id": item
                    ])
                }
                continue
            }
            
            Logger.info("Skipping cleanup check for item without metadata", metadata: ["item": item])
        }
    }
    
    func pull(image: String, name: String?) async throws {
        // Validate home directory
        let home = Home()
        try home.validateHomeDirectory()
        
        // Use provided name or derive from image
        let vmName = name ?? image.split(separator: ":").first.map(String.init) ?? ""
        let vmDir = home.getVMDirectory(vmName)
        
        // Parse image name and tag
        let components = image.split(separator: ":")
        guard components.count == 2 else {
            throw PullError.invalidImageFormat
        }
        let imageName = String(components[0])
        let tag = String(components[1])
        
        // Get anonymous token
        Logger.info("Getting registry authentication token")
        let token = try await getToken(repository: "\(self.organization)/\(imageName)")
        
        // Fetch manifest
        Logger.info("Fetching Image manifest")
        let (manifest, manifestDigest): (Manifest, String) = try await fetchManifest(
            repository: "\(self.organization)/\(imageName)",
            tag: tag,
            token: token
        )
        
        // Get manifest identifier using the manifest's own digest
        let manifestId = getManifestIdentifier(manifest, manifestDigest: manifestDigest)
        
        Logger.info("Pulling image", metadata: [
            "repository": imageName,
            "manifest_id": manifestId
        ])
        
        // Create VM directory
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: vmDir.dir.path), withIntermediateDirectories: true)
        
        // Check if we have a valid cached version
        Logger.info("Checking cache for manifest ID: \(manifestId)")
        if validateCache(manifest: manifest, manifestId: manifestId) {
            Logger.info("Using cached version of image")
            try await copyFromCache(manifest: manifest, manifestId: manifestId, to: URL(fileURLWithPath: vmDir.dir.path))
            return
        }
        
        // Clean up old versions of this repository before setting up new cache
        try cleanupOldVersions(currentManifestId: manifestId, image: imageName)
        
        Logger.info("Cache miss or invalid cache, setting up new cache")
        // Setup new cache directory
        try setupImageCache(manifestId: manifestId)
        
        // Save new manifest
        try saveManifest(manifest, manifestId: manifestId)
        
        // Save image metadata
        try saveImageMetadata(
            image: imageName,
            manifestId: manifestId
        )
        
        // Create temporary directory for new downloads
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Set total size and file count
        let totalFiles = manifest.layers.filter { $0.mediaType != "application/vnd.oci.empty.v1+json" }.count
        let totalSize = manifest.layers.reduce(0) { $0 + Int64($1.size) }
        Logger.info("Total download size: \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
        await progress.setTotal(totalSize, files: totalFiles)
        
        // Process layers with limited concurrency
        Logger.info("Processing Image layers")
        Logger.info("This may take several minutes depending on the image size and your internet connection. Please wait...")
        var diskParts: [(Int, URL)] = []
        var totalParts = 0
        let maxConcurrentTasks = 5
        let counter = TaskCounter()
        
        try await withThrowingTaskGroup(of: Int64.self) { group in
            for layer in manifest.layers {
                if layer.mediaType == "application/vnd.oci.empty.v1+json" {
                    continue
                }
                
                while await counter.current() >= maxConcurrentTasks {
                    _ = try await group.next()
                    await counter.decrement()
                }
                
                let outputURL: URL
                if let partInfo = extractPartInfo(from: layer.mediaType) {
                    let (partNum, total) = partInfo
                    totalParts = total
                    outputURL = tempDir.appendingPathComponent("disk.img.part.\(partNum)")
                    diskParts.append((partNum, outputURL))
                } else {
                    switch layer.mediaType {
                    case "application/vnd.oci.image.layer.v1.tar":
                        outputURL = tempDir.appendingPathComponent("disk.img")
                    case "application/vnd.oci.image.config.v1+json":
                        outputURL = tempDir.appendingPathComponent("config.json")
                    case "application/octet-stream":
                        outputURL = tempDir.appendingPathComponent("nvram.bin")
                    default:
                        continue
                    }
                }
                
                group.addTask { @Sendable [self] in
                    await counter.increment()
                    
                    let cachedLayer = getCachedLayerPath(manifestId: manifestId, digest: layer.digest)
                    
                    if FileManager.default.fileExists(atPath: cachedLayer.path) {
                        try FileManager.default.copyItem(at: cachedLayer, to: outputURL)
                        await progress.addProgress(Int64(layer.size))
                    } else {
                        // Check if this layer is already being downloaded
                        if isDownloading(layer.digest) {
                            try await waitForExistingDownload(layer.digest, cachedLayer: cachedLayer)
                            if FileManager.default.fileExists(atPath: cachedLayer.path) {
                                try FileManager.default.copyItem(at: cachedLayer, to: outputURL)
                                await progress.addProgress(Int64(layer.size))
                                return Int64(layer.size)
                            }
                        }
                        
                        // Start new download
                        markDownloadStarted(layer.digest)
                        defer { markDownloadComplete(layer.digest) }
                        
                        try await self.downloadLayer(
                            repository: "\(self.organization)/\(imageName)",
                            digest: layer.digest,
                            mediaType: layer.mediaType,
                            token: token,
                            to: outputURL,
                            maxRetries: 5,
                            progress: progress
                        )
                        
                        // Cache the downloaded layer
                        if FileManager.default.fileExists(atPath: cachedLayer.path) {
                            try FileManager.default.removeItem(at: cachedLayer)
                        }
                        try FileManager.default.copyItem(at: outputURL, to: cachedLayer)
                    }
                    
                    return Int64(layer.size)
                }
            }
            
            // Wait for remaining tasks
            for try await _ in group { }
        }
        Logger.info("") // New line after progress
        
        // Handle disk parts if present
        if !diskParts.isEmpty {
            Logger.info("Reassembling disk image...")
            let outputURL = URL(fileURLWithPath: vmDir.dir.path).appendingPathComponent("disk.img")
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            
            // Create empty output file
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }
            
            var totalWritten: UInt64 = 0
            let expectedTotalSize = UInt64(manifest.layers.filter { extractPartInfo(from: $0.mediaType) != nil }.reduce(0) { $0 + $1.size })
            
            // Process parts in order
            for partNum in 1...totalParts {
                guard let (_, partURL) = diskParts.first(where: { $0.0 == partNum }) else {
                    throw PullError.missingPart(partNum)
                }
                
                let inputHandle = try FileHandle(forReadingFrom: partURL)
                defer { 
                    try? inputHandle.close()
                    try? FileManager.default.removeItem(at: partURL)
                }
                
                // Read and write in chunks to minimize memory usage
                let chunkSize = 10 * 1024 * 1024 // 10MB chunks
                while let chunk = try inputHandle.read(upToCount: chunkSize) {
                    try outputHandle.write(contentsOf: chunk)
                    totalWritten += UInt64(chunk.count)
                    let progress: Double = Double(totalWritten) / Double(expectedTotalSize) * 100
                    Logger.info("Reassembling disk image: \(Int(progress))%")
                }
            }
            
            // Verify final size
            let finalSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? UInt64 ?? 0
            Logger.info("Final disk image size: \(ByteCountFormatter.string(fromByteCount: Int64(finalSize), countStyle: .file))")
            Logger.info("Expected size: \(ByteCountFormatter.string(fromByteCount: Int64(expectedTotalSize), countStyle: .file))")
            
            if finalSize != expectedTotalSize {
                Logger.info("Warning: Final size (\(finalSize) bytes) differs from expected size (\(expectedTotalSize) bytes)")
            }
            
            Logger.info("Disk image reassembled successfully")
        } else {
            // Copy single disk image if it exists
            let diskURL = tempDir.appendingPathComponent("disk.img")
            if FileManager.default.fileExists(atPath: diskURL.path) {
                try FileManager.default.copyItem(
                    at: diskURL,
                    to: URL(fileURLWithPath: vmDir.dir.path).appendingPathComponent("disk.img")
                )
            }
        }
        
        // Copy config and nvram files if they exist
        for file in ["config.json", "nvram.bin"] {
            let sourceURL = tempDir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: URL(fileURLWithPath: vmDir.dir.path).appendingPathComponent(file)
                )
            }
        }
        
        Logger.info("Download complete: Files extracted to \(vmDir.dir.path)")
    }
    
    private func copyFromCache(manifest: Manifest, manifestId: String, to destination: URL) async throws {
        Logger.info("Copying from cache...")
        var diskParts: [(Int, URL)] = []
        var totalParts = 0
        var expectedTotalSize: UInt64 = 0
        
        for layer in manifest.layers {
            let cachedLayer = getCachedLayerPath(manifestId: manifestId, digest: layer.digest)
            
            if let partInfo = extractPartInfo(from: layer.mediaType) {
                let (partNum, total) = partInfo
                totalParts = total
                let partURL = destination.appendingPathComponent("disk.img.part.\(partNum)")
                try FileManager.default.copyItem(at: cachedLayer, to: partURL)
                diskParts.append((partNum, partURL))
                expectedTotalSize += UInt64(layer.size)
            } else {
                let fileName: String
                switch layer.mediaType {
                case "application/vnd.oci.image.layer.v1.tar":
                    fileName = "disk.img"
                case "application/vnd.oci.image.config.v1+json":
                    fileName = "config.json"
                case "application/octet-stream":
                    fileName = "nvram.bin"
                default:
                    continue
                }
                try FileManager.default.copyItem(
                    at: cachedLayer,
                    to: destination.appendingPathComponent(fileName)
                )
            }
        }
        
        // Reassemble disk parts if needed
        if !diskParts.isEmpty {
            Logger.info("Reassembling disk image from cached parts...")
            let outputURL = destination.appendingPathComponent("disk.img")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }
            
            var totalWritten: UInt64 = 0
            
            for partNum in 1...totalParts {
                guard let (_, partURL) = diskParts.first(where: { $0.0 == partNum }) else {
                    throw PullError.missingPart(partNum)
                }
                
                let inputHandle = try FileHandle(forReadingFrom: partURL)
                while let data = try inputHandle.read(upToCount: 1024 * 1024 * 10) {
                    try outputHandle.write(contentsOf: data)
                    totalWritten += UInt64(data.count)
                }
                try inputHandle.close()
                try FileManager.default.removeItem(at: partURL)
            }
            
            // Verify final size
            let finalSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? UInt64 ?? 0
            Logger.info("Final disk image size: \(ByteCountFormatter.string(fromByteCount: Int64(finalSize), countStyle: .file))")
            Logger.info("Expected size: \(ByteCountFormatter.string(fromByteCount: Int64(expectedTotalSize), countStyle: .file))")
            
            if finalSize != expectedTotalSize {
                Logger.info("Warning: Final size (\(finalSize) bytes) differs from expected size (\(expectedTotalSize) bytes)")
            }
        }
        
        Logger.info("Cache copy complete")
    }
    
    private func getToken(repository: String) async throws -> String {
        let url = URL(string: "https://\(self.registry)/token")!
            .appending(queryItems: [
                URLQueryItem(name: "service", value: self.registry),
                URLQueryItem(name: "scope", value: "repository:\(repository):pull")
            ])
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["token"] as? String else {
            throw PullError.tokenFetchFailed
        }
        return token
    }
    
    private func fetchManifest(repository: String, tag: String, token: String) async throws -> (Manifest, String) {
        var request = URLRequest(url: URL(string: "https://\(self.registry)/v2/\(repository)/manifests/\(tag)")!)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.addValue("application/vnd.oci.image.manifest.v1+json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let digest = httpResponse.value(forHTTPHeaderField: "Docker-Content-Digest") else {
            throw PullError.manifestFetchFailed
        }
        
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        return (manifest, digest)
    }
    
    private func downloadLayer(
        repository: String,
        digest: String,
        mediaType: String,
        token: String,
        to url: URL,
        maxRetries: Int = 5,
        progress: isolated ProgressTracker
    ) async throws {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                var request = URLRequest(url: URL(string: "https://\(self.registry)/v2/\(repository)/blobs/\(digest)")!)
                request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.addValue(mediaType, forHTTPHeaderField: "Accept")
                request.timeoutInterval = 60
                
                // Configure session for better reliability
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 3600
                config.waitsForConnectivity = true
                config.httpMaximumConnectionsPerHost = 1
                
                let session = URLSession(configuration: config)
                
                let (tempURL, response) = try await session.download(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    throw PullError.layerDownloadFailed(digest)
                }
                
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: tempURL, to: url)
                progress.addProgress(Int64(httpResponse.expectedContentLength))
                return
                
            } catch {
                lastError = error
                if attempt < maxRetries {
                    let delay = Double(attempt) * 5
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? PullError.layerDownloadFailed(digest)
    }
    
    private func decompressGzipFile(at source: URL, to destination: URL) throws {
        Logger.info("Decompressing \(source.lastPathComponent)...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c"]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        
        try process.run()
        
        // Read and pipe the gzipped file in chunks to avoid memory issues
        let inputHandle = try FileHandle(forReadingFrom: source)
        let outputHandle = try FileHandle(forWritingTo: destination)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
        }
        
        // Create the output file
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        
        // Process in 10MB chunks
        let chunkSize = 10 * 1024 * 1024
        while let chunk = try inputHandle.read(upToCount: chunkSize) {
            try inputPipe.fileHandleForWriting.write(contentsOf: chunk)
            
            // Read and write output in chunks as well
            while let decompressedChunk = try outputPipe.fileHandleForReading.read(upToCount: chunkSize) {
                try outputHandle.write(contentsOf: decompressedChunk)
            }
        }
        
        try inputPipe.fileHandleForWriting.close()
        
        // Read any remaining output
        while let decompressedChunk = try outputPipe.fileHandleForReading.read(upToCount: chunkSize) {
            try outputHandle.write(contentsOf: decompressedChunk)
        }
        
        process.waitUntilExit()
        
        if process.terminationStatus != 0 {
            throw PullError.decompressionFailed(source.lastPathComponent)
        }
        
        // Verify the decompressed size
        let decompressedSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? UInt64 ?? 0
        Logger.info("Decompressed size: \(ByteCountFormatter.string(fromByteCount: Int64(decompressedSize), countStyle: .file))")
    }
    
    private func extractPartInfo(from mediaType: String) -> (partNum: Int, total: Int)? {
        let pattern = #"part\.number=(\d+);part\.total=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: mediaType,
                range: NSRange(mediaType.startIndex..., in: mediaType)
              ),
              let partNumRange = Range(match.range(at: 1), in: mediaType),
              let totalRange = Range(match.range(at: 2), in: mediaType),
              let partNum = Int(mediaType[partNumRange]),
              let total = Int(mediaType[totalRange]) else {
            return nil
        }
        return (partNum, total)
    }
    
    private func listRepositories() async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://\(registry)/v2/\(organization)/repositories/list")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PullError.manifestFetchFailed
        }
        
        if httpResponse.statusCode == 404 {
            return []
        }
        
        guard httpResponse.statusCode == 200 else {
            throw PullError.manifestFetchFailed
        }
        
        let repoList = try JSONDecoder().decode(RepositoryList.self, from: data)
        return repoList.repositories
    }

    func getImages() async throws -> [CachedImage] {
        Logger.info("Scanning for cached images in \(cacheDirectory.path)")
        var images: [CachedImage] = []
        let orgDir = cacheDirectory.appendingPathComponent(organization)
        
        if FileManager.default.fileExists(atPath: orgDir.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: orgDir.path)
            Logger.info("Found \(contents.count) items in cache directory")
            
            for item in contents {
                let itemPath = orgDir.appendingPathComponent(item)
                var isDirectory: ObjCBool = false
                
                guard FileManager.default.fileExists(atPath: itemPath.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                
                // First try to read metadata file
                let metadataPath = itemPath.appendingPathComponent("metadata.json")
                if let metadataData = try? Data(contentsOf: metadataPath),
                   let metadata = try? JSONDecoder().decode(ImageMetadata.self, from: metadataData) {
                    Logger.info("Found metadata for image", metadata: [
                        "image": metadata.image,
                        "manifest_id": metadata.manifestId
                    ])
                    images.append(CachedImage(
                        repository: metadata.image,
                        imageId: String(metadata.manifestId.prefix(12)),
                        manifestId: metadata.manifestId
                    ))
                    continue
                }
                
                // Fallback to checking manifest if metadata doesn't exist
                Logger.info("No metadata found for \(item), checking manifest")
                let manifestPath = itemPath.appendingPathComponent("manifest.json")
                guard FileManager.default.fileExists(atPath: manifestPath.path),
                      let manifestData = try? Data(contentsOf: manifestPath),
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
                    Logger.info("No valid manifest found for \(item)")
                    continue
                }
                
                let manifestId = item
                
                // Verify the manifest ID matches
                let currentManifestId = getManifestIdentifier(manifest, manifestDigest: "")
                Logger.info("Manifest check", metadata: [
                    "item": item,
                    "current_manifest_id": currentManifestId,
                    "matches": "\(currentManifestId == manifestId)"
                ])
                if currentManifestId == manifestId {
                    // Skip if we can't determine the repository name
                    // This should be rare since we now save metadata during pull
                    Logger.info("Skipping image without metadata: \(item)")
                    continue
                }
            }
        } else {
            Logger.info("Cache directory does not exist")
        }
        
        Logger.info("Found \(images.count) cached images")
        return images.sorted { $0.repository == $1.repository ? $0.imageId < $1.imageId : $0.repository < $1.repository }
    }

    private func listRemoteImageTags(repository: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://\(registry)/v2/\(organization)/\(repository)/tags/list")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PullError.manifestFetchFailed
        }
        
        if httpResponse.statusCode == 404 {
            return []
        }
        
        guard httpResponse.statusCode == 200 else {
            throw PullError.manifestFetchFailed
        }
        
        let repoTags = try JSONDecoder().decode(RepositoryTags.self, from: data)
        return repoTags.tags
    }
}