import ArgumentParser
import Foundation
import Virtualization

@MainActor
extension Server {
    // MARK: - VM Management Handlers

    func handleListVMs(storage: String? = nil) async throws -> HTTPResponse {
        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiVMList)

        do {
            let vmController = LumeController()
            let vms = try vmController.list(storage: storage)
            return try .json(vms)
        } catch {
            print(
                "ERROR: Failed to list VMs: \(error.localizedDescription), storage=\(String(describing: storage))"
            )
            return .badRequest(message: error.localizedDescription)
        }
    }

    func handleGetVM(name: String, storage: String? = nil) async throws -> HTTPResponse {
        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiVMGet)

        // Check if an async pull is in progress for this VM name
        let pullProgress = await PullProgressTracker.shared.getProgress(for: name)
        let pullError = await PullProgressTracker.shared.getError(for: name)

        if let errorMsg = pullError {
            // Pull failed — surface the error
            return .badRequest(message: "Pull failed for '\(name)': \(errorMsg)")
        }

        if let progress = pullProgress {
            // Pull in progress — return a synthetic "pulling" status without hitting disk
            let responseBody: [String: AnyEncodable] = [
                "name": AnyEncodable(name),
                "status": AnyEncodable("pulling"),
                "downloadProgress": AnyEncodable(progress),
            ]
            return try HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: JSONEncoder().encode(responseBody)
            )
        }

        do {
            let vmController = LumeController()
            // Use getDetails() for consistent status including provisioning state
            let details = try vmController.getDetails(name: name, storage: storage)
            return try HTTPResponse.json(details)
        } catch {
            return .badRequest(message: error.localizedDescription)
        }
    }

    func handlePullStart(_ body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(PullRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        let imageName = request.image.split(separator: ":").first.map(String.init) ?? request.image
        TelemetryClient.shared.record(event: TelemetryEvent.apiPull, properties: [
            "image_name": imageName
        ])

        let vmName = request.name ?? imageName
        await PullProgressTracker.shared.setProgress(0.0, for: vmName)

        Task.detached { @MainActor @Sendable in
            do {
                let vmController = LumeController()
                try await vmController.pullImage(
                    image: request.image,
                    name: request.name,
                    registry: request.registry,
                    organization: request.organization,
                    storage: request.storage,
                    progressHandler: { pct in
                        Task { await PullProgressTracker.shared.setProgress(pct, for: vmName) }
                    }
                )
                await PullProgressTracker.shared.complete(for: vmName)
                Logger.info("Async pull completed", metadata: ["name": vmName])
            } catch {
                await PullProgressTracker.shared.setError(error.localizedDescription, for: vmName)
                Logger.error("Async pull failed", metadata: ["name": vmName, "error": error.localizedDescription])
            }
        }

        return HTTPResponse(
            statusCode: .accepted,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode([
                "message": AnyEncodable("Pull started"),
                "name": AnyEncodable(vmName),
                "image": AnyEncodable(request.image),
            ])
        )
    }

    func handleCreateVM(_ body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(CreateVMRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiVMCreate, properties: [
            "os_type": request.os.lowercased(),
            "cpu": request.cpu,
            "memory": request.memory,
            "disk_size": request.diskSize
        ])

        do {
            let sizes = try request.parse()
            let vmController = LumeController()

            // Load unattended config if specified
            var unattendedConfig: UnattendedConfig? = nil
            if let unattendedArg = request.unattended {
                unattendedConfig = try UnattendedConfig.load(from: unattendedArg)
            }

            let networkMode = try request.parseNetworkMode()

            // Use async create - returns immediately while VM is provisioned in background
            try vmController.createAsync(
                name: request.name,
                os: request.os,
                diskSize: sizes.diskSize,
                cpuCount: request.cpu,
                memorySize: sizes.memory,
                display: request.display,
                ipsw: request.ipsw,
                storage: request.storage,
                unattendedConfig: unattendedConfig,
                networkMode: networkMode
            )

            // Return 202 Accepted - VM creation is in progress
            return HTTPResponse(
                statusCode: .accepted,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode([
                    "message": "VM creation started",
                    "name": request.name,
                    "status": "provisioning",
                ])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handleDeleteVM(name: String, storage: String? = nil) async throws -> HTTPResponse {
        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiVMDelete)

        do {
            let vmController = LumeController()
            try await vmController.delete(name: name, storage: storage)
            return HTTPResponse(
                statusCode: .ok, headers: ["Content-Type": "application/json"], body: Data())
        } catch {
            return HTTPResponse(
                statusCode: .badRequest, headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription)))
        }
    }

    func handleCloneVM(_ body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(CloneRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiVMClone)

        do {
            let vmController = LumeController()
            try vmController.clone(
                name: request.name,
                newName: request.newName,
                sourceLocation: request.sourceLocation,
                destLocation: request.destLocation
            )

            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode([
                    "message": "VM cloned successfully",
                    "source": request.name,
                    "destination": request.newName,
                ])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    // MARK: - VM Metadata Handlers
    //
    // Per-VM user-editable metadata (creator / description / owner) lives in
    // a sidecar JSON file `bushel-metadata.json` inside the VM's directory.
    // See `VMMetadataStore` for the storage details. These handlers expose
    // the sidecar over HTTP so the dashboard's Edit dialog can read and
    // write it.

    /// GET /lume/vms/:name/metadata
    /// Returns the sidecar JSON. Returns `{}` when the VM has no sidecar.
    /// Returns 404 if the named VM doesn't exist in any storage location.
    func handleGetMetadata(name: String, storage: String?) async throws -> HTTPResponse {
        do {
            let vmController = LumeController()

            // Resolve the actual storage location so the metadata read goes
            // to the right place when the VM lives in a non-default location.
            // validateVMExists throws VMError.notFound — we surface that as a
            // clean 404 rather than the default 400.
            let actualLocation: String?
            do {
                actualLocation = try vmController.validateVMExists(name, storage: storage)
            } catch VMError.notFound {
                return HTTPResponse(
                    statusCode: .notFound,
                    headers: ["Content-Type": "application/json"],
                    body: try JSONEncoder().encode(APIError(message: "VM not found: \(name)"))
                )
            }

            let store = VMMetadataStore(home: vmController.home)
            let metadata = store.load(name: name, storage: actualLocation)
            return try HTTPResponse.json(metadata)
        } catch {
            return .badRequest(message: error.localizedDescription)
        }
    }

    /// PUT /lume/vms/:name/metadata
    /// Replaces the sidecar with the supplied JSON. Unknown fields are
    /// rejected (400) so a typo'd field name surfaces immediately. The
    /// `updated_at` field in the body is silently ignored — the server
    /// stamps it on every write.
    /// Returns the metadata as actually persisted (i.e. with the server-set
    /// `updated_at`).
    func handlePutMetadata(name: String, storage: String?, body: Data?) async throws -> HTTPResponse {
        guard let body = body else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(
                    APIError(message: "Request body is required"))
            )
        }

        // Parse the body. We decode into VMMetadata directly; an unexpected
        // type (e.g. `creator: 42`) makes JSONDecoder throw, which we surface
        // as a 400 with a useful message rather than a generic 500.
        let decoded: VMMetadata
        do {
            decoded = try JSONDecoder().decode(VMMetadata.self, from: body)
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(
                    APIError(message: "Invalid metadata JSON: \(error.localizedDescription)"))
            )
        }

        let vmController = LumeController()

        // 404 when the VM doesn't exist. The store would otherwise happily
        // create a sidecar in an empty/non-existent dir, which is not what
        // we want — the issue says "validates VM exists".
        let actualLocation: String?
        do {
            actualLocation = try vmController.validateVMExists(name, storage: storage)
        } catch VMError.notFound {
            return HTTPResponse(
                statusCode: .notFound,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "VM not found: \(name)"))
            )
        }

        // Strip any client-supplied updated_at; the store re-stamps it
        // anyway, but doing it here too makes the contract obvious to
        // anyone reading this code.
        var toWrite = decoded
        toWrite.updatedAt = nil

        do {
            let store = VMMetadataStore(home: vmController.home)
            let written = try store.save(toWrite, name: name, storage: actualLocation)
            return try HTTPResponse.json(written)
        } catch {
            return .badRequest(message: error.localizedDescription)
        }
    }

    // MARK: - VM Operation Handlers

    func handleSetVM(name: String, body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(SetVMRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiVMUpdate)

        do {
            let vmController = LumeController()
            let sizes = try request.parse()
            try vmController.updateSettings(
                name: name,
                cpu: request.cpu,
                memory: sizes.memory,
                diskSize: sizes.diskSize,
                display: sizes.display?.string,
                storage: request.storage
            )

            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["message": "VM settings updated successfully"])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handleStopVM(name: String, storage: String? = nil) async throws -> HTTPResponse {
        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiVMStop)

        Logger.info(
            "Stopping VM", metadata: ["name": name, "storage": String(describing: storage)])

        do {
            Logger.info("Creating VM controller", metadata: ["name": name])
            let vmController = LumeController()

            Logger.info("Calling stopVM on controller", metadata: ["name": name])
            try await vmController.stopVM(name: name, storage: storage)

            Logger.info(
                "VM stopped, waiting 5 seconds for locks to clear", metadata: ["name": name])

            // Add a delay to ensure locks are fully released before returning
            for i in 1...5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                Logger.info("Lock clearing delay", metadata: ["name": name, "seconds": "\(i)/5"])
            }

            // Verify the VM is really in a stopped state
            Logger.info("Verifying VM is stopped", metadata: ["name": name])
            let vm = try? vmController.get(name: name, storage: storage)
            if let vm = vm, vm.details.status == "running" {
                Logger.info(
                    "VM still reports as running despite stop operation",
                    metadata: ["name": name, "severity": "warning"])
            } else {
                Logger.info(
                    "Verification complete: VM is in stopped state", metadata: ["name": name])
            }

            Logger.info("Returning successful response", metadata: ["name": name])
            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["message": "VM stopped successfully"])
            )
        } catch {
            Logger.error(
                "Failed to stop VM",
                metadata: [
                    "name": name,
                    "error": error.localizedDescription,
                    "storage": String(describing: storage),
                ])
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handleSetupVM(name: String, body: Data?) async throws -> HTTPResponse {
        Logger.info("Setting up VM", metadata: ["name": name])

        guard let body = body else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Request body is required"))
            )
        }

        do {
            let request = try JSONDecoder().decode(SetupVMRequest.self, from: body)

            // Load config from path or parse YAML directly
            let config: UnattendedConfig
            if let configPath = request.configPath {
                config = try UnattendedConfig.load(from: configPath)
            } else if let configYaml = request.configYaml {
                config = try UnattendedConfig.parse(yaml: configYaml)
            } else {
                return HTTPResponse(
                    statusCode: .badRequest,
                    headers: ["Content-Type": "application/json"],
                    body: try JSONEncoder().encode(APIError(message: "Either configPath or configYaml is required"))
                )
            }

            // Run setup in background task since it can take a long time
            Task {
                do {
                    let vmController = LumeController()
                    try await vmController.setup(
                        name: name,
                        config: config,
                        storage: request.storage,
                        vncPort: request.vncPort ?? 0,
                        noDisplay: request.noDisplay ?? true,
                        debug: request.debug ?? false,
                        debugDir: request.debugDir
                    )
                    Logger.info("Unattended setup completed", metadata: ["name": name])
                } catch {
                    Logger.error("Unattended setup failed", metadata: [
                        "name": name,
                        "error": error.localizedDescription
                    ])
                }
            }

            return HTTPResponse(
                statusCode: .accepted,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["message": "Setup started", "name": name])
            )
        } catch {
            Logger.error("Failed to start setup", metadata: [
                "name": name,
                "error": error.localizedDescription
            ])
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handleRunVM(name: String, body: Data?) async throws -> HTTPResponse {
        Logger.info("Running VM", metadata: ["name": name])

        // Log the raw body data if available
        if let body = body, let bodyString = String(data: body, encoding: .utf8) {
            Logger.info("Run VM raw request body", metadata: ["name": name, "body": bodyString])
        } else {
            Logger.info("No request body or could not decode as string", metadata: ["name": name])
        }

        do {
            Logger.info("Creating VM controller and parsing request", metadata: ["name": name])
            let request =
                body.flatMap { try? JSONDecoder().decode(RunVMRequest.self, from: $0) }
                ?? RunVMRequest(
                    noDisplay: nil, sharedDirectories: nil, recoveryMode: nil, storage: nil,
                    diskPath: nil, nvramPath: nil, network: nil, clipboard: nil)

            // Record telemetry
            TelemetryClient.shared.record(event: TelemetryEvent.apiVMRun, properties: [
                "headless": request.noDisplay ?? false
            ])

            Logger.info(
                "Parsed request",
                metadata: [
                    "name": name,
                    "noDisplay": String(describing: request.noDisplay),
                    "sharedDirectories": "\(request.sharedDirectories?.count ?? 0)",
                    "storage": String(describing: request.storage),
                ])

            Logger.info("Parsing shared directories", metadata: ["name": name])
            let dirs = try request.parse()
            Logger.info(
                "Successfully parsed shared directories",
                metadata: ["name": name, "count": "\(dirs.count)"])

            let networkMode = try request.parseNetworkMode()

            // Start VM in background
            Logger.info("Starting VM in background", metadata: ["name": name])
            startVM(
                name: name,
                noDisplay: request.noDisplay ?? false,
                sharedDirectories: dirs,
                recoveryMode: request.recoveryMode ?? false,
                storage: request.storage,
                diskPath: request.diskPath.map { Path($0) },
                nvramPath: request.nvramPath.map { Path($0) },
                networkMode: networkMode,
                clipboard: request.clipboard ?? false
            )
            Logger.info("VM start initiated in background", metadata: ["name": name])

            // Return response immediately
            return HTTPResponse(
                statusCode: .accepted,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode([
                    "message": "VM start initiated",
                    "name": name,
                    "status": "pending",
                ])
            )
        } catch {
            Logger.error(
                "Failed to run VM",
                metadata: [
                    "name": name,
                    "error": error.localizedDescription,
                ])
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    // MARK: - Image Management Handlers

    func handleIPSW() async throws -> HTTPResponse {
        do {
            let vmController = LumeController()
            let url = try await vmController.getLatestIPSWURL()
            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["url": url.absoluteString])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handlePull(_ body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(PullRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        // Record telemetry - strip version tag from image name for privacy
        let imageName = request.image.split(separator: ":").first.map(String.init) ?? request.image
        TelemetryClient.shared.record(event: TelemetryEvent.apiPull, properties: [
            "image_name": imageName
        ])

        do {
            let vmName = request.name ?? (request.image.split(separator: ":").first.map(String.init) ?? request.image)
            await PullProgressTracker.shared.setProgress(0.0, for: vmName)
            let vmController = LumeController()
            try await vmController.pullImage(
                image: request.image,
                name: request.name,
                registry: request.registry,
                organization: request.organization,
                storage: request.storage,
                progressHandler: { pct in
                    Task { await PullProgressTracker.shared.setProgress(pct, for: vmName) }
                }
            )
            await PullProgressTracker.shared.complete(for: vmName)

            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode([
                    "message": "Image pulled successfully",
                    "image": request.image,
                    "name": request.name ?? "default",
                ])
            )
        } catch {
            let vmName = request.name ?? (request.image.split(separator: ":").first.map(String.init) ?? request.image)
            await PullProgressTracker.shared.setError(error.localizedDescription, for: vmName)
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handlePruneImages() async throws -> HTTPResponse {
        do {
            let vmController = LumeController()
            try await vmController.pruneImages()
            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["message": "Successfully removed cached images"])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handlePush(_ body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(PushRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiPush)

        // Trigger push asynchronously, return Accepted immediately
        Task.detached { @MainActor @Sendable in
            do {
                let vmController = LumeController()
                try await vmController.pushImage(
                    name: request.name,
                    imageName: request.imageName,
                    tags: request.tags,
                    registry: request.registry,
                    organization: request.organization,
                    storage: request.storage,
                    chunkSizeMb: request.chunkSizeMb,
                    verbose: false,  // Verbose typically handled by server logs
                    dryRun: false,  // Default API behavior is likely non-dry-run
                    reassemble: false,  // Default API behavior is likely non-reassemble
                    singleLayer: request.singleLayer
                )
                print(
                    "Background push completed successfully for image: \(request.imageName):\(request.tags.joined(separator: ","))"
                )
            } catch {
                print(
                    "Background push failed for image: \(request.imageName):\(request.tags.joined(separator: ",")) - Error: \(error.localizedDescription)"
                )
            }
        }

        return HTTPResponse(
            statusCode: .accepted,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode([
                "message": AnyEncodable("Push initiated in background"),
                "name": AnyEncodable(request.name),
                "imageName": AnyEncodable(request.imageName),
                "tags": AnyEncodable(request.tags),
            ])
        )
    }

    func handleGetImages(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Record telemetry
        TelemetryClient.shared.record(event: TelemetryEvent.apiImages)

        let pathAndQuery = request.path.split(separator: "?", maxSplits: 1)
        let queryParams =
            pathAndQuery.count > 1
            ? pathAndQuery[1]
                .split(separator: "&")
                .reduce(into: [String: String]()) { dict, param in
                    let parts = param.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        dict[String(parts[0])] = String(parts[1])
                    }
                } : [:]

        let organization = queryParams["organization"] ?? "trycua"

        do {
            let vmController = LumeController()
            let imageList = try await vmController.getImages(organization: organization)

            // Create a response format that matches the CLI output
            let response = imageList.local.map {
                [
                    "repository": $0.repository,
                    "imageId": $0.imageId,
                ]
            }

            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(response)
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    // MARK: - Config Management Handlers

    func handleGetConfig() async throws -> HTTPResponse {
        do {
            let vmController = LumeController()
            let settings = vmController.getSettings()
            return try .json(settings)
        } catch {
            return .badRequest(message: error.localizedDescription)
        }
    }

    struct ConfigRequest: Codable {
        let homeDirectory: String?
        let cacheDirectory: String?
        let cachingEnabled: Bool?
    }

    func handleUpdateConfig(_ body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(ConfigRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        do {
            let vmController = LumeController()

            if let homeDir = request.homeDirectory {
                try vmController.setHomeDirectory(homeDir)
            }

            if let cacheDir = request.cacheDirectory {
                try vmController.setCacheDirectory(path: cacheDir)
            }

            if let cachingEnabled = request.cachingEnabled {
                try vmController.setCachingEnabled(cachingEnabled)
            }

            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["message": "Configuration updated successfully"])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handleGetLocations() async throws -> HTTPResponse {
        do {
            let vmController = LumeController()
            let locations = vmController.getLocations()
            return try .json(locations)
        } catch {
            return .badRequest(message: error.localizedDescription)
        }
    }

    struct LocationRequest: Codable {
        let name: String
        let path: String
    }

    func handleAddLocation(_ body: Data?) async throws -> HTTPResponse {
        guard let body = body,
            let request = try? JSONDecoder().decode(LocationRequest.self, from: body)
        else {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: "Invalid request body"))
            )
        }

        do {
            let vmController = LumeController()
            try vmController.addLocation(name: request.name, path: request.path)

            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode([
                    "message": "Location added successfully",
                    "name": request.name,
                    "path": request.path,
                ])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handleRemoveLocation(_ name: String) async throws -> HTTPResponse {
        do {
            let vmController = LumeController()
            try vmController.removeLocation(name: name)
            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["message": "Location removed successfully"])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    func handleSetDefaultLocation(_ name: String) async throws -> HTTPResponse {
        do {
            let vmController = LumeController()
            try vmController.setDefaultLocation(name: name)
            return HTTPResponse(
                statusCode: .ok,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(["message": "Default location set successfully"])
            )
        } catch {
            return HTTPResponse(
                statusCode: .badRequest,
                headers: ["Content-Type": "application/json"],
                body: try JSONEncoder().encode(APIError(message: error.localizedDescription))
            )
        }
    }

    // MARK: - Log Handlers

    func handleGetLogs(type: String?, lines: Int?) async throws -> HTTPResponse {
        do {
            let logType = type?.lowercased() ?? "all"
            let infoPath = "/tmp/lume_daemon.log"
            let errorPath = "/tmp/lume_daemon.error.log"

            let fileManager = FileManager.default
            var response: [String: String] = [:]

            // Function to read log files
            func readLogFile(path: String) -> String? {
                guard fileManager.fileExists(atPath: path) else {
                    return nil
                }

                do {
                    let content = try String(contentsOfFile: path, encoding: .utf8)

                    // If lines parameter is provided, return only the specified number of lines from the end
                    if let lineCount = lines {
                        let allLines = content.components(separatedBy: .newlines)
                        let startIndex = max(0, allLines.count - lineCount)
                        let lastLines = Array(allLines[startIndex...])
                        return lastLines.joined(separator: "\n")
                    }

                    return content
                } catch {
                    return "Error reading log file: \(error.localizedDescription)"
                }
            }

            // Get logs based on requested type
            if logType == "info" || logType == "all" {
                response["info"] = readLogFile(path: infoPath) ?? "Info log file not found"
            }

            if logType == "error" || logType == "all" {
                response["error"] = readLogFile(path: errorPath) ?? "Error log file not found"
            }

            return try .json(response)
        } catch {
            return .badRequest(message: error.localizedDescription)
        }
    }

    // MARK: - Host Status Handler

    /// Response structure for host status endpoint
    struct HostStatusResponse: Codable {
        let status: String
        let vmCount: Int
        let maxVMs: Int
        let availableSlots: Int
        let version: String

        enum CodingKeys: String, CodingKey {
            case status
            case vmCount = "vm_count"
            case maxVMs = "max_vms"
            case availableSlots = "available_slots"
            case version
        }
    }

    // MARK: - noVNC Viewer Handlers

    /// Handle GET /vnc/:name - Serve the vendored noVNC HTML page with the
    /// VM name substituted in. The page auto-connects to the same daemon's
    /// /vnc/:name/ws WebSocket endpoint, which is intercepted at the
    /// channel-pipeline level (see installVNCBridge in Server.swift).
    func handleVNCViewer(name: String) async throws -> HTTPResponse {
        // Same loopback-only assumption as everything else in this server.
        // VM name has no validation here because the WS bridge re-resolves
        // the VM via LumeController and will fail cleanly if it's bogus —
        // saves us a second name-validation regex.

        guard let url = Bundle.lumeResources.url(forResource: "novnc/vnc", withExtension: "html"),
              let data = try? Data(contentsOf: url),
              let template = String(data: data, encoding: .utf8)
        else {
            Logger.error("novnc/vnc.html missing from resource bundle")
            return HTTPResponse(
                statusCode: .internalServerError,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("novnc/vnc.html missing from resource bundle".utf8)
            )
        }

        // The VM name appears in two different syntactic contexts in the
        // template, each requiring its own escape:
        //
        //   1. HTML text/attribute (in <title>, <span>) — escape the standard
        //      "<>&\"'" set so a hostile name can't break out of the tag.
        //   2. JavaScript string literal (`const VM_NAME = ...`) — HTML
        //      escaping is WRONG here: `&amp;` would land in the JS string as
        //      five literal characters, and the WS URL would have a `&amp;`
        //      where the user typed `&`. JSON-encode instead; JSON's string
        //      grammar is a superset of JS string literals (modulo U+2028 /
        //      U+2029 which JSONEncoder happens to NOT emit unescaped on
        //      Apple platforms, but we hardening-escape them anyway below).
        //
        // We use distinct placeholders for the two contexts so the template
        // remains explicit about which substitution lands where.
        let htmlEscaped = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")

        // JSON-encode the name. Produces a complete quoted string literal
        // (e.g. `"foo&bar"`), so the template embeds it directly as
        // `const VM_NAME = __BUSHEL_VM_NAME_JSON__;` with no surrounding
        // quotes. JSONEncoder.encode handles unicode and edge cases
        // (control chars, lone surrogates, etc.) correctly.
        let encoder = JSONEncoder()
        // U+2028 (LINE SEPARATOR) and U+2029 (PARAGRAPH SEPARATOR) are valid
        // in JSON strings but are line terminators in JS — they'd break a
        // single-line string literal. Replace them with \u-escapes after
        // encoding. (JSONEncoder on Apple platforms does NOT emit these
        // unescaped today, but defending against any future encoder change.)
        var jsonEncoded: String
        if let jsonData = try? encoder.encode(name),
           let raw = String(data: jsonData, encoding: .utf8) {
            jsonEncoded = raw
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        } else {
            // Should never happen — JSONEncoder for a String can fail only on
            // pathological surrogate input. Fall back to an empty string
            // literal rather than letting the page render unparseable JS.
            jsonEncoded = "\"\""
        }

        let html = template
            .replacingOccurrences(of: "__BUSHEL_VM_NAME_HTML__", with: htmlEscaped)
            .replacingOccurrences(of: "__BUSHEL_VM_NAME_JSON__", with: jsonEncoded)

        return HTTPResponse(
            statusCode: .ok,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                // The HTML itself rarely changes, but the JS assets are
                // vendored at a specific noVNC version and shouldn't be
                // cached aggressively across upgrades.
                "Cache-Control": "no-cache",
            ],
            body: Data(html.utf8)
        )
    }

    /// Handle GET /vnc/static/<path> - Serve a vendored noVNC asset.
    /// Variable-depth path; matched via prefix check in handleRequest, not
    /// the route table. Content-Type is derived from the file extension.
    func handleVNCStatic(assetPath: String) async -> HTTPResponse {
        // Reject any path traversal — only allow simple relative paths.
        // Reject empty segments, leading "/", any ".." segment.
        guard !assetPath.isEmpty,
              !assetPath.hasPrefix("/"),
              !assetPath.contains("..")
        else {
            return HTTPResponse(statusCode: .badRequest, body: "Invalid asset path")
        }

        // SPM resource bundles preserve directory structure when you .copy()
        // a directory. Bundle.url(forResource:) doesn't take subdirectories
        // gracefully, so use the bundle's resourceURL directly.
        guard let bundleURL = Bundle.lumeResources.resourceURL else {
            return HTTPResponse(statusCode: .internalServerError, body: "Resource bundle missing")
        }
        let fileURL = bundleURL.appendingPathComponent("novnc").appendingPathComponent(assetPath)

        // Confirm the resolved path is still inside the novnc directory —
        // belt-and-suspenders against any path traversal we missed.
        let novncRoot = bundleURL.appendingPathComponent("novnc").standardizedFileURL.path
        let resolvedPath = fileURL.standardizedFileURL.path
        guard resolvedPath.hasPrefix(novncRoot + "/") || resolvedPath == novncRoot else {
            return HTTPResponse(statusCode: .badRequest, body: "Invalid asset path")
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return HTTPResponse(statusCode: .notFound, body: "Not found")
        }

        let ext = (assetPath as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "js", "mjs": contentType = "application/javascript; charset=utf-8"
        case "css":       contentType = "text/css; charset=utf-8"
        case "html":      contentType = "text/html; charset=utf-8"
        case "json":      contentType = "application/json; charset=utf-8"
        case "png":       contentType = "image/png"
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "gif":       contentType = "image/gif"
        case "svg":       contentType = "image/svg+xml"
        case "ico":       contentType = "image/x-icon"
        case "woff":      contentType = "font/woff"
        case "woff2":     contentType = "font/woff2"
        case "txt":       contentType = "text/plain; charset=utf-8"
        default:          contentType = "application/octet-stream"
        }

        return HTTPResponse(
            statusCode: .ok,
            headers: [
                "Content-Type": contentType,
                // noVNC assets are fingerprinted by version (we bumped on
                // each upgrade). Allow brief caching to reduce repeat
                // fetches when a user reopens the viewer.
                "Cache-Control": "public, max-age=300",
            ],
            body: data
        )
    }

    /// Handle GET / and GET /dashboard - Serve the built-in web dashboard HTML.
    /// The HTML talks to the same daemon (relative URLs), so no external Python
    /// server or LUME_DAEMON_URL configuration is needed. Replaces the
    /// "install lume-web-vm-manager separately" friction with one curl-bash.
    func handleDashboard() async throws -> HTTPResponse {
        guard let url = Bundle.lumeResources.url(forResource: "dashboard", withExtension: "html"),
              let data = try? Data(contentsOf: url)
        else {
            Logger.error("dashboard.html missing from resource bundle")
            return HTTPResponse(
                statusCode: .internalServerError,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                body: Data("dashboard.html missing from resource bundle".utf8)
            )
        }
        return HTTPResponse(
            statusCode: .ok,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                // Disable caching: the dashboard's JS pulls /lume/vms on its own
                // schedule, but the HTML itself can change between releases and
                // we don't want stale UI shown after an upgrade.
                "Cache-Control": "no-cache, no-store, must-revalidate",
            ],
            body: data
        )
    }

    /// Handle GET /lume/host/status - Report host capacity and health for orchestrator
    func handleGetHostStatus() async throws -> HTTPResponse {
        do {
            let vmController = LumeController()

            // Get all VMs across all storage locations
            let vms = try vmController.list(storage: nil)

            // Count running VMs (Apple policy: max 2 VMs per host)
            let runningVMs = vms.filter { $0.status == "running" }
            let maxVMs = 2  // Apple Virtualization Framework limit

            let response = HostStatusResponse(
                status: "healthy",
                vmCount: runningVMs.count,
                maxVMs: maxVMs,
                availableSlots: max(0, maxVMs - runningVMs.count),
                version: "1.0.0"  // Could be derived from build info
            )

            return try .json(response)
        } catch {
            Logger.error("Failed to get host status", metadata: ["error": error.localizedDescription])
            return .badRequest(message: error.localizedDescription)
        }
    }

    // MARK: - Private Helper Methods

    nonisolated private func startVM(
        name: String,
        noDisplay: Bool,
        sharedDirectories: [SharedDirectory] = [],
        recoveryMode: Bool = false,
        storage: String? = nil,
        diskPath: Path? = nil,
        nvramPath: Path? = nil,
        networkMode: NetworkMode? = nil,
        clipboard: Bool = false
    ) {
        Logger.info(
            "Starting VM in detached task",
            metadata: [
                "name": name,
                "noDisplay": "\(noDisplay)",
                "recoveryMode": "\(recoveryMode)",
                "storage": String(describing: storage),
                "networkMode": networkMode?.description ?? "vm-config",
            ])

        Task.detached { @MainActor @Sendable in
            Logger.info("Background task started for VM", metadata: ["name": name])
            do {
                Logger.info("Creating VM controller in background task", metadata: ["name": name])
                let vmController = LumeController()

                Logger.info(
                    "Calling runVM on controller",
                    metadata: [
                        "name": name,
                        "noDisplay": "\(noDisplay)",
                    ])
                try await vmController.runVM(
                    name: name,
                    noDisplay: noDisplay,
                    sharedDirectories: sharedDirectories,
                    recoveryMode: recoveryMode,
                    storage: storage,
                    diskPath: diskPath,
                    nvramPath: nvramPath,
                    networkMode: networkMode,
                    clipboard: clipboard
                )
                Logger.info("VM started successfully in background task", metadata: ["name": name])
            } catch {
                Logger.error(
                    "Failed to start VM in background task",
                    metadata: [
                        "name": name,
                        "error": error.localizedDescription,
                    ])
            }
        }
        Logger.info("Background task dispatched for VM", metadata: ["name": name])
    }
}
