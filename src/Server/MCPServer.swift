import Foundation
import MCP

/// MCP (Model Context Protocol) server for Lume VM management
/// Allows AI agents like Claude to manage VMs through MCP tools
@MainActor
final class LumeMCPServer {
    private let controller: LumeController
    private var mcpServer: MCP.Server?

    init(controller: LumeController) {
        self.controller = controller
    }

    func start() async throws {
        mcpServer = MCP.Server(
            name: "bushel",
            version: "1.0.0",
            capabilities: .init(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await registerHandlers()

        let transport = StdioTransport()
        try await mcpServer?.start(transport: transport)
        await mcpServer?.waitUntilCompleted()
    }

    private func registerHandlers() async {
        // Register ListTools handler
        await mcpServer?.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self = self else {
                return ListTools.Result(tools: [])
            }
            return await MainActor.run {
                ListTools.Result(tools: self.toolDefinitions)
            }
        }

        // Register CallTool handler
        await mcpServer?.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(content: [.text("Server not available")], isError: true)
            }
            return await self.handleToolCall(params)
        }

        // Register ListResources handler
        await mcpServer?.withMethodHandler(ListResources.self) { [weak self] _ in
            guard let self = self else {
                return ListResources.Result(resources: [])
            }
            return await MainActor.run {
                ListResources.Result(resources: self.resourceDefinitions)
            }
        }

        // Register ReadResource handler
        await mcpServer?.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self = self else {
                return ReadResource.Result(contents: [])
            }
            return await MainActor.run {
                self.handleReadResource(params)
            }
        }

        // Register ListPrompts handler
        await mcpServer?.withMethodHandler(ListPrompts.self) { [weak self] _ in
            guard let self = self else {
                return ListPrompts.Result(prompts: [])
            }
            return await MainActor.run {
                ListPrompts.Result(prompts: self.promptDefinitions)
            }
        }

        // Register GetPrompt handler
        await mcpServer?.withMethodHandler(GetPrompt.self) { [weak self] params in
            guard let self = self else {
                return GetPrompt.Result(description: nil, messages: [])
            }
            return await MainActor.run {
                self.handleGetPrompt(params)
            }
        }
    }

    // MARK: - Resource Definitions

    private var resourceDefinitions: [Resource] {
        [
            Resource(
                name: "Lume Usage Guide",
                uri: "lume://usage-guide",
                description: "Best practices and workflows for managing macOS VMs with Lume",
                mimeType: "text/markdown"
            ),
            Resource(
                name: "Default Credentials",
                uri: "lume://credentials",
                description: "Default SSH credentials for VMs created with unattended setup",
                mimeType: "text/plain"
            )
        ]
    }

    private func handleReadResource(_ params: ReadResource.Parameters) -> ReadResource.Result {
        switch params.uri {
        case "lume://usage-guide":
            return ReadResource.Result(contents: [
                .text(usageGuideContent, uri: params.uri, mimeType: "text/markdown")
            ])
        case "lume://credentials":
            return ReadResource.Result(contents: [
                .text(credentialsContent, uri: params.uri, mimeType: "text/plain")
            ])
        default:
            return ReadResource.Result(contents: [])
        }
    }

    private var usageGuideContent: String {
        """
        # Lume VM Management Guide

        ## Overview
        Lume manages macOS virtual machines on Apple Silicon. Use these tools to create, run, and manage VMs for sandboxed development and testing.

        ## Typical Workflow

        ### 1. Check Existing VMs
        Always start by listing VMs to see what's available:
        ```
        lume_list_vms
        ```

        ### 2. Create a New VM (if needed)
        Creating a VM takes 15-30 minutes. Use `unattended: "tahoe"` for automatic setup with SSH enabled:
        ```
        lume_create_vm(name: "sandbox", unattended: "tahoe")
        ```
        The tool returns immediately. Poll `lume_list_vms` to monitor progress—status changes from `provisioning (ipsw_install)` → `running` (during unattended setup) → `stopped`.

        ### 3. Start the VM
        Start with optional shared directory for file access:
        ```
        lume_start_vm(name: "sandbox", shared_dir: "~/project", no_display: true)
        ```
        Shared files appear in the VM at `/Volumes/My Shared Files/`.

        ### 4. Execute Commands
        Run commands via SSH:
        ```
        lume_exec(name: "sandbox", command: "cd /Volumes/My\\\\ Shared\\\\ Files && npm test")
        ```

        ### 5. Stop the VM
        ```
        lume_stop_vm(name: "sandbox")
        ```

        ## Best Practices

        ### VM Naming
        - Use descriptive names: `dev-sandbox`, `test-runner`, `build-agent`
        - Avoid spaces and special characters

        ### Resource Allocation
        - Default: 4 CPU cores, 8GB RAM, 64GB disk
        - For builds: Consider 8 CPU cores, 16GB RAM
        - Disk grows dynamically (sparse files)

        ### Unattended Presets
        - `tahoe`: macOS Tahoe with SSH enabled, user `lume`/`lume`
        - `sequoia`: macOS Sequoia with SSH enabled, user `lume`/`lume`

        ### Golden Images
        Create a fully configured VM, then clone it for fast resets:
        ```
        lume_clone_vm(name: "configured-vm", new_name: "fresh-sandbox")
        ```

        ### Shared Directories
        - Read-write by default
        - Path in VM: `/Volumes/My Shared Files/`
        - Escape spaces in commands: `My\\ Shared\\ Files`

        ## Status Reference

        | Status | Meaning |
        |--------|---------|
        | `stopped` | Ready to start |
        | `running` | VM is active |
        | `provisioning (ipsw_install)` | Installing macOS |
        | `running` | VM is running (including during unattended setup) |

        ## Limitations
        - Max 2 macOS VMs running simultaneously (Apple licensing)
        - Linux VMs: Unlimited
        - Nested virtualization: Not supported for macOS guests
        """
    }

    private var credentialsContent: String {
        """
        Default credentials for VMs created with --unattended tahoe or sequoia:

        Username: lume
        Password: lume

        SSH is enabled automatically. Connect with:
        ssh lume@<vm-ip-address>

        Get VM IP with lume_get_vm(name: "vm-name")
        """
    }

    // MARK: - Prompt Definitions

    private var promptDefinitions: [Prompt] {
        [
            Prompt(
                name: "create-sandbox",
                description: "Create a new macOS sandbox VM with unattended setup",
                arguments: [
                    .init(name: "name", description: "Name for the new VM", required: true)
                ]
            ),
            Prompt(
                name: "run-in-sandbox",
                description: "Run a command in an existing sandbox VM",
                arguments: [
                    .init(name: "vm_name", description: "Name of the VM", required: true),
                    .init(name: "command", description: "Command to execute", required: true)
                ]
            ),
            Prompt(
                name: "reset-sandbox",
                description: "Reset a sandbox by cloning from a golden image",
                arguments: [
                    .init(name: "golden_image", description: "Name of the golden image VM", required: true),
                    .init(name: "sandbox_name", description: "Name for the fresh sandbox", required: true)
                ]
            )
        ]
    }

    private func handleGetPrompt(_ params: GetPrompt.Parameters) -> GetPrompt.Result {
        switch params.name {
        case "create-sandbox":
            let vmName = params.arguments?["name"] ?? "sandbox"
            return GetPrompt.Result(
                description: "Create a macOS sandbox VM",
                messages: [
                    .user("""
                        Create a new macOS sandbox VM named '\(vmName)' with these requirements:
                        1. Use unattended setup (tahoe preset) for automatic configuration
                        2. The VM should have SSH enabled with credentials lume/lume
                        3. Monitor the provisioning status until complete
                        4. Once ready, start the VM in headless mode
                        5. Verify SSH connectivity by running a simple command
                        """)
                ]
            )

        case "run-in-sandbox":
            let vmName = params.arguments?["vm_name"] ?? "sandbox"
            let command = params.arguments?["command"] ?? "echo 'Hello from sandbox'"
            return GetPrompt.Result(
                description: "Run command in sandbox VM",
                messages: [
                    .user("""
                        Run this command in the '\(vmName)' VM:
                        ```
                        \(command)
                        ```

                        Steps:
                        1. First check if the VM exists and is running (lume_list_vms)
                        2. If stopped, start it with lume_start_vm
                        3. Wait for it to be reachable (lume_wait_for_vm with condition: "ssh_ready")
                        4. Execute the command with lume_exec
                        5. Report the output
                        """)
                ]
            )

        case "reset-sandbox":
            let goldenImage = params.arguments?["golden_image"] ?? "golden"
            let sandboxName = params.arguments?["sandbox_name"] ?? "sandbox"
            return GetPrompt.Result(
                description: "Reset sandbox from golden image",
                messages: [
                    .user("""
                        Reset the sandbox by cloning from the golden image:
                        1. Stop '\(sandboxName)' if it's running
                        2. Delete '\(sandboxName)' if it exists
                        3. Clone '\(goldenImage)' to '\(sandboxName)'
                        4. Start the new '\(sandboxName)' VM
                        5. Verify it's working with a simple SSH command
                        """)
                ]
            )

        default:
            return GetPrompt.Result(description: nil, messages: [])
        }
    }

    // MARK: - Tool Definitions

    private var toolDefinitions: [Tool] {
        [
            Tool(
                name: "lume_list_vms",
                description: "List all virtual machines with their status, IP addresses, and resource allocation",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path to filter VMs")
                        ])
                    ])
                ])
            ),
            Tool(
                name: "lume_get_vm",
                description: "Get detailed information about a specific VM including IP address, VNC URL, and SSH availability",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "lume_start_vm",
                description: "Start a VM with optional shared directory and host-clipboard sharing. Shared dir appears at /Volumes/My Shared Files inside the VM. Returns immediately while the VM boots — use lume_wait_for_vm with condition='ssh_ready' to wait until the VM is reachable. (Also accepts the legacy name 'lume_run_vm'.)",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM to start")
                        ]),
                        "shared_dir": .object([
                            "type": .string("string"),
                            "description": .string("Host directory path to share with the VM (appears at /Volumes/My Shared Files)")
                        ]),
                        "no_display": .object([
                            "type": .string("boolean"),
                            "description": .string("Run headless without VNC window (default: true)")
                        ]),
                        "clipboard": .object([
                            "type": .string("boolean"),
                            "description": .string("Share clipboard between host and VM (default: false). Requires macOS 15+ on host and guest.")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "lume_stop_vm",
                description: "Stop a running VM gracefully",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM to stop")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "lume_clone_vm",
                description: "Clone a VM to create a copy. Useful for creating golden images for instant reset.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of the source VM to clone")
                        ]),
                        "new_name": .object([
                            "type": .string("string"),
                            "description": .string("Name for the cloned VM")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("new_name")])
                ])
            ),
            Tool(
                name: "lume_delete_vm",
                description: "Delete a VM and all its associated files",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM to delete")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "lume_exec",
                description: "Execute a command inside a running VM via SSH. Requires SSH to be enabled in the VM (default for VMs created with --unattended tahoe).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM")
                        ]),
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("Shell command to execute inside the VM")
                        ]),
                        "user": .object([
                            "type": .string("string"),
                            "description": .string("SSH username (default: lume)")
                        ]),
                        "password": .object([
                            "type": .string("string"),
                            "description": .string("SSH password (default: lume)")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("command")])
                ])
            ),
            Tool(
                name: "lume_create_vm",
                description: "Create a new VM asynchronously. Returns immediately while the VM is provisioned. Poll lume_list_vms / lume_get_vm or block via lume_wait_for_vm to track progress. Supports macOS (requires IPSW; can run unattended Setup Assistant) and Linux (empty disk, IPSW not used).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name for the new VM")
                        ]),
                        "os": .object([
                            "type": .string("string"),
                            "enum": .array([.string("macos"), .string("linux")]),
                            "description": .string("Operating system (default: 'macos'). Linux VMs ignore 'ipsw' and 'unattended'.")
                        ]),
                        "ipsw": .object([
                            "type": .string("string"),
                            "description": .string("[macOS only] Path to IPSW file or 'latest' to download (default: 'latest')")
                        ]),
                        "unattended": .object([
                            "type": .string("string"),
                            "description": .string("[macOS only] Unattended Setup Assistant preset name ('tahoe', 'sequoia') or path to a YAML config")
                        ]),
                        "cpu": .object([
                            "type": .string("integer"),
                            "description": .string("Number of CPU cores (default: 4)")
                        ]),
                        "memory": .object([
                            "type": .string("string"),
                            "description": .string("Memory size, e.g., '8GB' (default: 8GB)")
                        ]),
                        "disk_size": .object([
                            "type": .string("string"),
                            "description": .string("Disk size, e.g., '64GB' (default: 64GB)")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "lume_wait_for_vm",
                description: "Block until a VM reaches a requested state (or timeout). Replaces the manual polling loop agents would otherwise have to write around lume_get_vm. Most agents want condition='ssh_ready', which means the VM is running AND SSH is reachable on it.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM to wait on")
                        ]),
                        "condition": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("running"),
                                .string("stopped"),
                                .string("ssh_ready"),
                                .string("provisioning_complete")
                            ]),
                            "description": .string("Default 'ssh_ready'. 'running' = VM in running state. 'stopped' = VM stopped. 'ssh_ready' = running AND SSH reachable. 'provisioning_complete' = VM finished initial setup (status no longer 'provisioning').")
                        ]),
                        "timeout_seconds": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum seconds to wait. Default: 300 (5 min). For freshly created macOS VMs, allow 600+ to cover IPSW install and Setup Assistant.")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "lume_pull_image",
                description: "Pull a pre-built VM image from a container registry (e.g. ghcr.io/trycua/macos-sequoia-vanilla:latest, ubuntu-noble-vanilla:latest) into local storage. Async — returns immediately while the download proceeds in the background. Large macOS images can take 5–30 minutes; use lume_list_vms or lume_get_vm with the resolved VM name to detect when the VM appears in the local list. Linux pulls are typically 1–5 minutes.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "image": .object([
                            "type": .string("string"),
                            "description": .string("Image reference in 'name:tag' format, e.g. 'macos-sequoia-vanilla:latest'")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Local VM name to assign (default: derived from image name)")
                        ]),
                        "registry": .object([
                            "type": .string("string"),
                            "description": .string("Registry host (default: ghcr.io)")
                        ]),
                        "organization": .object([
                            "type": .string("string"),
                            "description": .string("Registry organization (default: trycua)")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("image")])
                ])
            ),
            Tool(
                name: "lume_host_status",
                description: "Report host capacity: how many VMs are currently running, the maximum allowed by Apple Virtualization.framework (2 on macOS), and how many slots remain. Use this before starting or creating a new VM to avoid hitting the concurrency cap.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            )
        ]
    }

    // MARK: - Tool Call Handler

    private func handleToolCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case "lume_list_vms":
                return try await handleListVMs(params.arguments)
            case "lume_get_vm":
                return try await handleGetVM(params.arguments)
            case "lume_run_vm", "lume_start_vm":  // run_vm kept as legacy alias
                return try await handleRunVM(params.arguments)
            case "lume_stop_vm":
                return try await handleStopVM(params.arguments)
            case "lume_clone_vm":
                return try await handleCloneVM(params.arguments)
            case "lume_delete_vm":
                return try await handleDeleteVM(params.arguments)
            case "lume_exec":
                return try await handleExec(params.arguments)
            case "lume_create_vm":
                return try await handleCreateVM(params.arguments)
            case "lume_pull_image":
                return try await handlePullImage(params.arguments)
            case "lume_host_status":
                return try await handleHostStatus(params.arguments)
            case "lume_wait_for_vm":
                return try await handleWaitForVM(params.arguments)
            default:
                return MCPResponse.error(
                    operation: "unknown",
                    code: "unknown_tool",
                    message: "Unknown tool: \(params.name)"
                )
            }
        } catch {
            // Strip the "lume_" prefix so the operation name in the response is
            // just "list_vms", "start_vm", etc.
            let op = params.name.hasPrefix("lume_") ? String(params.name.dropFirst(5)) : params.name
            return MCPResponse.error(operation: op, throwing: error)
        }
    }

    // MARK: - Tool Implementations

    private func handleListVMs(_ args: [String: Value]?) async throws -> CallTool.Result {
        let storage = args?["storage"]?.stringValue
        let vms = try controller.list(storage: storage)
        // Re-serialize via Codable then parse back to [Any] so the envelope's
        // JSONSerialization-based payload can include the structured VM list.
        let encoded = try JSONEncoder().encode(vms)
        let asArray = (try JSONSerialization.jsonObject(with: encoded) as? [Any]) ?? []
        return MCPResponse.success(operation: "list_vms", resultArray: asArray)
    }

    private func handleGetVM(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "get_vm", code: "validation_error", message: "'name' is required")
        }
        let storage = args?["storage"]?.stringValue

        // getDetails() returns a status that reflects provisioning state too (not just running/stopped).
        let vmDetails = try controller.getDetails(name: name, storage: storage)
        let encoded = try JSONEncoder().encode(vmDetails)
        let asDict = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
        return MCPResponse.success(operation: "get_vm", result: asDict)
    }

    private func handleRunVM(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "start_vm", code: "validation_error", message: "'name' is required")
        }

        let storage = args?["storage"]?.stringValue
        let noDisplay = args?["no_display"]?.boolValue ?? true
        let clipboard = args?["clipboard"]?.boolValue ?? false

        var sharedDirectories: [SharedDirectory] = []
        if let sharedDir = args?["shared_dir"]?.stringValue {
            let expandedPath = (sharedDir as NSString).expandingTildeInPath
            sharedDirectories.append(SharedDirectory(hostPath: expandedPath, tag: "shared", readOnly: false))
        }

        // Run VM in detached task to avoid blocking (same pattern as HTTP API).
        // Errors here surface to logs only; the agent should call lume_wait_for_vm
        // with condition='ssh_ready' to get a typed signal of actual readiness.
        Task.detached { @MainActor @Sendable in
            do {
                let vmController = LumeController()
                try await vmController.runVM(
                    name: name,
                    noDisplay: noDisplay,
                    sharedDirectories: sharedDirectories,
                    storage: storage,
                    clipboard: clipboard
                )
            } catch {
                Logger.error(
                    "Failed to start VM in background task",
                    metadata: ["name": name, "error": error.localizedDescription])
            }
        }

        // Brief settle so the IP is usually populated by the time we return. The
        // agent's contract is "this kicks off start; use wait_for_vm for readiness."
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let vmDetails = try controller.getDetails(name: name, storage: storage)
        var result: [String: Any] = [
            "name": name,
            "status": vmDetails.status,
            "shared_dir_mounted": !sharedDirectories.isEmpty,
        ]
        if let ip = vmDetails.ipAddress {
            result["ip"] = ip
            result["ssh"] = "ssh lume@\(ip)"
        }
        return MCPResponse.success(
            operation: "start_vm",
            result: result,
            message: "VM '\(name)' starting. Use lume_wait_for_vm to wait for ssh_ready."
        )
    }

    private func handleStopVM(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "stop_vm", code: "validation_error", message: "'name' is required")
        }
        let storage = args?["storage"]?.stringValue

        try await controller.stopVM(name: name, storage: storage)
        return MCPResponse.success(
            operation: "stop_vm",
            result: ["name": name],
            message: "VM '\(name)' stopped."
        )
    }

    private func handleCloneVM(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "clone_vm", code: "validation_error", message: "'name' is required")
        }
        guard let newName = args?["new_name"]?.stringValue else {
            return MCPResponse.error(operation: "clone_vm", code: "validation_error", message: "'new_name' is required")
        }

        try controller.clone(name: name, newName: newName)
        return MCPResponse.success(
            operation: "clone_vm",
            result: ["source": name, "name": newName],
            message: "VM '\(name)' cloned to '\(newName)'."
        )
    }

    private func handleDeleteVM(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "delete_vm", code: "validation_error", message: "'name' is required")
        }
        let storage = args?["storage"]?.stringValue

        try await controller.delete(name: name, storage: storage)
        return MCPResponse.success(
            operation: "delete_vm",
            result: ["name": name],
            message: "VM '\(name)' deleted."
        )
    }

    private func handleExec(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "exec", code: "validation_error", message: "'name' is required")
        }
        guard let command = args?["command"]?.stringValue else {
            return MCPResponse.error(operation: "exec", code: "validation_error", message: "'command' is required")
        }

        let user = args?["user"]?.stringValue ?? "lume"
        let password = args?["password"]?.stringValue ?? "lume"
        let storage = args?["storage"]?.stringValue

        let vm = try controller.get(name: name, storage: storage)
        guard let ip = vm.details.ipAddress else {
            return MCPResponse.error(
                operation: "exec",
                code: "vm_not_running",
                message: "VM '\(name)' has no IP address. Is it running?"
            )
        }

        if vm.details.sshAvailable == false {
            return MCPResponse.error(
                operation: "exec",
                code: "ssh_unavailable",
                message: "SSH is not available on VM '\(name)'. Wait for ssh_ready or ensure SSH is enabled in the VM."
            )
        }

        let sshClient = SSHClient(host: ip, port: 22, user: user, password: password)

        do {
            // SSHClient.execute merges stdout and stderr into a single output string;
            // splitting them is tracked separately. Exit code is exposed here so the
            // agent can branch on it without parsing free text.
            let sshResult = try await sshClient.execute(command: command, timeout: 60)
            let payload: [String: Any] = [
                "exit_code": sshResult.exitCode,
                "output": sshResult.output,
            ]
            if sshResult.exitCode == 0 {
                return MCPResponse.success(
                    operation: "exec",
                    result: payload,
                    message: "Command completed (exit 0)."
                )
            } else {
                // Non-zero exit is a real signal the agent should usually act on, so
                // return as error with a typed code, but include exit_code + output
                // in the message so the agent can still see what happened.
                let body: [String: Any] = [
                    "ok": false,
                    "operation": "exec",
                    "error": ["code": "command_failed", "message": "Command exited with code \(sshResult.exitCode)"],
                    "result": payload,
                ]
                let data = (try? JSONSerialization.data(
                    withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                return CallTool.Result(
                    content: [.text(String(data: data, encoding: .utf8) ?? "{}")],
                    isError: true
                )
            }
        } catch {
            return MCPResponse.error(operation: "exec", throwing: error)
        }
    }

    private func handleCreateVM(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "create_vm", code: "validation_error", message: "'name' is required")
        }

        let osValue = (args?["os"]?.stringValue ?? "macos").lowercased()
        guard ["macos", "linux"].contains(osValue) else {
            return MCPResponse.error(
                operation: "create_vm",
                code: "validation_error",
                message: "'os' must be 'macos' or 'linux', got '\(osValue)'"
            )
        }

        let unattendedPreset = args?["unattended"]?.stringValue
        let cpuCount = args?["cpu"]?.intValue ?? 4
        let storage = args?["storage"]?.stringValue

        // Parse memory size (default 8GB)
        let memorySize: UInt64
        if let memoryStr = args?["memory"]?.stringValue {
            memorySize = try parseSize(memoryStr)
        } else {
            memorySize = 8 * 1024 * 1024 * 1024  // 8GB default
        }

        // Parse disk size (default 64GB)
        let diskSize: UInt64
        if let diskStr = args?["disk_size"]?.stringValue {
            diskSize = try parseSize(diskStr)
        } else {
            diskSize = 64 * 1024 * 1024 * 1024  // 64GB default
        }

        // IPSW only applies to macOS; Linux VMs use an empty disk and reject ipsw at
        // the validation layer. unattended setup is also macOS-only.
        let ipsw: String?
        var unattendedConfig: UnattendedConfig? = nil
        if osValue == "macos" {
            ipsw = args?["ipsw"]?.stringValue ?? "latest"
            if let preset = unattendedPreset {
                unattendedConfig = try UnattendedConfig.load(from: preset)
            }
        } else {
            ipsw = nil
        }

        // Use async create - returns immediately
        try controller.createAsync(
            name: name,
            os: osValue,
            diskSize: diskSize,
            cpuCount: cpuCount,
            memorySize: memorySize,
            display: "1920x1080",
            ipsw: ipsw,
            storage: storage,
            unattendedConfig: unattendedConfig
        )

        var result: [String: Any] = [
            "name": name,
            "os": osValue,
            "status": "provisioning",
            "cpu": cpuCount,
            "memory_bytes": memorySize,
            "disk_bytes": diskSize,
        ]
        if let ipsw = ipsw { result["ipsw"] = ipsw }
        result["unattended"] = unattendedConfig != nil
        var msg = "VM '\(name)' creation started (\(osValue)). Use lume_wait_for_vm to track."
        if unattendedConfig != nil {
            msg += " Unattended setup will run automatically after IPSW installation."
        }
        return MCPResponse.success(operation: "create_vm", result: result, message: msg)
    }

    private func handlePullImage(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let image = args?["image"]?.stringValue else {
            return MCPResponse.error(
                operation: "pull_image",
                code: "validation_error",
                message: "'image' is required (e.g. 'macos-sequoia-vanilla:latest')"
            )
        }

        let parts = image.split(separator: ":")
        guard parts.count == 2 else {
            return MCPResponse.error(
                operation: "pull_image",
                code: "validation_error",
                message: "Image must be in 'name:tag' format, got '\(image)'"
            )
        }

        let name = args?["name"]?.stringValue
        let registry = args?["registry"]?.stringValue ?? "ghcr.io"
        let organization = args?["organization"]?.stringValue ?? "trycua"
        let storage = args?["storage"]?.stringValue
        let vmName = name ?? String(parts[0])

        // Mirrors the async-detached pattern in Handlers.handlePullStart so progress
        // is tracked the same way for HTTP and MCP callers. PR-followup will surface
        // PullProgressTracker.shared as a queryable MCP resource.
        await PullProgressTracker.shared.setProgress(0.0, for: vmName)
        Task.detached { @MainActor @Sendable in
            do {
                let vmController = LumeController()
                try await vmController.pullImage(
                    image: image,
                    name: name,
                    registry: registry,
                    organization: organization,
                    storage: storage,
                    progressHandler: { pct in
                        Task { await PullProgressTracker.shared.setProgress(pct, for: vmName) }
                    }
                )
                await PullProgressTracker.shared.complete(for: vmName)
                Logger.info("MCP pull completed", metadata: ["name": vmName])
            } catch {
                await PullProgressTracker.shared.setError(error.localizedDescription, for: vmName)
                Logger.error(
                    "MCP pull failed",
                    metadata: ["name": vmName, "error": error.localizedDescription])
            }
        }

        return MCPResponse.success(
            operation: "pull_image",
            result: [
                "image": image,
                "name": vmName,
                "registry": registry,
                "organization": organization,
                "status": "pulling",
            ],
            message: "Pull started for '\(image)' to VM '\(vmName)'. Linux: 1–5 min, macOS: 5–30 min. Use lume_get_vm or lume_wait_for_vm to track."
        )
    }

    private func handleHostStatus(_ args: [String: Value]?) async throws -> CallTool.Result {
        _ = args  // host status takes no inputs

        let vms = try controller.list(storage: nil)
        let runningCount = vms.filter { $0.status == "running" }.count
        let maxVMs = 2  // Apple Virtualization.framework limit on concurrent VMs
        let availableSlots = max(0, maxVMs - runningCount)

        return MCPResponse.success(
            operation: "host_status",
            result: [
                "status": "healthy",
                "vm_count": runningCount,
                "max_vms": maxVMs,
                "available_slots": availableSlots,
                "version": Lume.Version.current,
            ]
        )
    }

    private func handleWaitForVM(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "wait_for_vm", code: "validation_error", message: "'name' is required")
        }
        let condition = (args?["condition"]?.stringValue ?? "ssh_ready").lowercased()
        let timeoutSec = args?["timeout_seconds"]?.intValue ?? 300
        let storage = args?["storage"]?.stringValue

        let validConditions = ["running", "stopped", "ssh_ready", "provisioning_complete"]
        guard validConditions.contains(condition) else {
            return MCPResponse.error(
                operation: "wait_for_vm",
                code: "validation_error",
                message: "'condition' must be one of \(validConditions.joined(separator: ", ")), got '\(condition)'"
            )
        }

        let start = Date()
        let deadline = start.addingTimeInterval(TimeInterval(timeoutSec))
        var lastStatus = "<unknown>"

        // 1-second poll. Cheap relative to the operations being waited on (boots,
        // shutdowns, IPSW installs); aggressive enough that agent tail latency stays
        // under a second once the condition is met.
        while Date() < deadline {
            do {
                let vm = try controller.getDetails(name: name, storage: storage)
                lastStatus = vm.status
                if conditionMet(condition, vm: vm) {
                    let elapsed = Int(Date().timeIntervalSince(start))
                    var result: [String: Any] = [
                        "name": name,
                        "condition": condition,
                        "status": vm.status,
                        "ssh_available": vm.sshAvailable ?? false,
                        "elapsed_seconds": elapsed,
                    ]
                    if let ip = vm.ipAddress { result["ip"] = ip }
                    return MCPResponse.success(
                        operation: "wait_for_vm",
                        result: result,
                        message: "VM '\(name)' reached '\(condition)' after \(elapsed)s."
                    )
                }
            } catch {
                // VM not yet visible (very early in provisioning) — keep polling until
                // timeout. Don't surface the error mid-loop; the agent learns enough
                // from the timeout message if it never resolves.
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        return MCPResponse.error(
            operation: "wait_for_vm",
            code: "wait_timeout",
            message: "VM '\(name)' did not reach '\(condition)' within \(timeoutSec)s. Last observed status: \(lastStatus)."
        )
    }

    private func conditionMet(_ condition: String, vm: VMDetails) -> Bool {
        switch condition {
        case "running":
            return vm.status == "running"
        case "stopped":
            return vm.status == "stopped"
        case "ssh_ready":
            return vm.status == "running" && (vm.sshAvailable ?? false)
        case "provisioning_complete":
            // Status leaves 'provisioning' AND the daemon clears the in-flight
            // provisioning operation marker. Both because either alone has been
            // observed to flap during the IPSW->Setup-Assistant handoff.
            return vm.status != "provisioning" && vm.provisioningOperation == nil
        default:
            return false
        }
    }
}

// MARK: - Value Extension for type-safe argument access

extension Value {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self {
            return value
        }
        return nil
    }
}
