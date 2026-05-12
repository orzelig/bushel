import AppKit
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
                description: "List all virtual machines with their status, IP addresses, and resource allocation. Snapshots (VMs whose name contains '__snap__') are filtered out by default — pass include_snapshots=true to see them.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path to filter VMs")
                        ]),
                        "include_snapshots": .object([
                            "type": .string("boolean"),
                            "description": .string("Include snapshot VMs in the listing (default: false). Use lume_snapshot_list for a structured view of one VM's snapshots.")
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
                description: "Clone a VM to create a copy. Backed by APFS clonefile() — near-instant on the same volume, copy-on-write disk usage. Useful for golden-image patterns. Source VM must be stopped.",
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
                        ]),
                        "source_storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location of the source VM")
                        ]),
                        "dest_storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location for the cloned VM (defaults to source_storage)")
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
                name: "lume_snapshot_create",
                description: "Snapshot a VM via APFS clonefile (near-instant copy-on-write — disk usage grows only as the snapshot diverges). The VM must be stopped: Apple Virtualization.framework doesn't support quiesced live snapshots, so call lume_stop_vm first if needed. The snapshot is stored as a hidden VM named '<vm>__snap__<name>'.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "vm": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM to snapshot. Must be stopped.")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Snapshot identifier. Cannot contain '__snap__'.")
                        ])
                    ]),
                    "required": .array([.string("vm"), .string("name")])
                ])
            ),
            Tool(
                name: "lume_snapshot_list",
                description: "List snapshots of a VM (VMs whose name matches '<vm>__snap__*').",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "vm": .object([
                            "type": .string("string"),
                            "description": .string("Name of the parent VM")
                        ])
                    ]),
                    "required": .array([.string("vm")])
                ])
            ),
            Tool(
                name: "lume_snapshot_restore",
                description: "Restore a VM from a snapshot. Deletes the current VM (if it exists) and clones the snapshot back to that name. Both the VM and its snapshot must be stopped. Idempotent: works even if the VM was previously deleted.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "vm": .object([
                            "type": .string("string"),
                            "description": .string("Name of the VM to restore (will be deleted then recreated from snapshot)")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Snapshot identifier to restore from")
                        ])
                    ]),
                    "required": .array([.string("vm"), .string("name")])
                ])
            ),
            Tool(
                name: "lume_snapshot_delete",
                description: "Delete a snapshot. The parent VM is unaffected.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "vm": .object([
                            "type": .string("string"),
                            "description": .string("Name of the parent VM")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Snapshot identifier to delete")
                        ])
                    ]),
                    "required": .array([.string("vm"), .string("name")])
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
                name: "lume_pull_status",
                description: "Report progress of an in-flight lume_pull_image. Returns 0.0–1.0 progress, an error string if the pull failed, or 'not_pulling' if no pull is in progress for that name (which also covers 'pull completed and the VM is now in the regular list').",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("VM name passed to (or derived for) lume_pull_image")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ])
            ),
            Tool(
                name: "lume_screen_capture",
                description: "Capture the VM's screen as a PNG (returned as an MCP image plus a JSON metadata sidecar). VM must be running with VNC available. Use this for vision-capable agents to see the macOS GUI.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of a running VM with VNC active")
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
                name: "lume_screen_click",
                description: "Send a mouse click at (x, y) inside the VM via VNC. Coordinates are in the VM's screen pixels (use lume_screen_capture to see what's there). VM must be running with VNC available.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of a running VM with VNC active")
                        ]),
                        "x": .object([
                            "type": .string("integer"),
                            "description": .string("X coordinate in VM screen pixels")
                        ]),
                        "y": .object([
                            "type": .string("integer"),
                            "description": .string("Y coordinate in VM screen pixels")
                        ]),
                        "button": .object([
                            "type": .string("string"),
                            "enum": .array([.string("left"), .string("middle"), .string("right")]),
                            "description": .string("Mouse button (default: left)")
                        ]),
                        "double": .object([
                            "type": .string("boolean"),
                            "description": .string("Send a double-click (default: false)")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("x"), .string("y")])
                ])
            ),
            Tool(
                name: "lume_screen_type",
                description: "Type text into the VM via VNC keyboard events (one keysym per character, with Shift held for capital letters and shifted symbols). Slow for long strings — for >50 chars prefer lume_screen_paste.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of a running VM with VNC active")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("Text to type. Newlines are sent as Return key presses.")
                        ]),
                        "delay_ms": .object([
                            "type": .string("integer"),
                            "description": .string("Delay between key presses in milliseconds (default: 50). Reduce for headless workflows; increase if the guest UI is dropping events.")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("text")])
                ])
            ),
            Tool(
                name: "lume_put_file",
                description: "Copy a file from the host into a running VM via SSH. Useful for dropping config files, scripts, or test fixtures into a sandbox. Limit: ~10 MB per file (the transport is base64-over-SSH-exec, which buffers in memory). For larger transfers, start the VM with shared_dir.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of a running VM with SSH available")
                        ]),
                        "host_path": .object([
                            "type": .string("string"),
                            "description": .string("Path on the host filesystem (~ is expanded)")
                        ]),
                        "vm_path": .object([
                            "type": .string("string"),
                            "description": .string("Destination path inside the VM. Parent directories must exist.")
                        ]),
                        "user": .object([
                            "type": .string("string"),
                            "description": .string("SSH user (default: lume)")
                        ]),
                        "password": .object([
                            "type": .string("string"),
                            "description": .string("SSH password (default: lume — the unattended-build VM credential)")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("host_path"), .string("vm_path")])
                ])
            ),
            Tool(
                name: "lume_get_file",
                description: "Copy a file from a running VM to the host via SSH. Same ~10 MB limit as lume_put_file (base64-over-SSH-exec buffers in memory). For larger transfers, mount a shared_dir.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of a running VM with SSH available")
                        ]),
                        "vm_path": .object([
                            "type": .string("string"),
                            "description": .string("Source path inside the VM")
                        ]),
                        "host_path": .object([
                            "type": .string("string"),
                            "description": .string("Destination path on the host filesystem (~ is expanded). Will be overwritten.")
                        ]),
                        "user": .object([
                            "type": .string("string"),
                            "description": .string("SSH user (default: lume)")
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
                    "required": .array([.string("name"), .string("vm_path"), .string("host_path")])
                ])
            ),
            Tool(
                name: "lume_screen_paste",
                description: "Paste text into the VM by writing to the host pasteboard and sending Cmd+V via VNC. Faster than lume_screen_type for long strings. Requires the VM's clipboard sync to be active (or call this only when the host's clipboard is what you want pasted).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of a running VM with VNC active")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("Text to write to the host pasteboard before sending Cmd+V")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ])
                    ]),
                    "required": .array([.string("name"), .string("text")])
                ])
            ),
            Tool(
                name: "lume_host_status",
                description: "Report host capacity: how many VMs are currently running, the maximum allowed by Apple Virtualization.framework (2 on macOS), and how many slots remain. Use this before starting or creating a new VM to avoid hitting the concurrency cap.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ),
            Tool(
                name: "lume_open_vnc",
                description: "Return a browser-openable URL for the VM's noVNC viewer (HTML + WebSocket bridge served by the daemon). Use this when the human needs to see the VM's screen interactively — vision agents should prefer lume_screen_capture for one-shot frames. VM must be running with VNC available. The `native_vnc_url` returned is redacted (password stripped) by default; set `include_password: true` to receive the full `vnc://:password@host:port` form. Note: `include_password: true` may surface the cleartext VNC password in MCP transport logs — set it only when the caller is trusted to handle that.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Name of a running VM with VNC active")
                        ]),
                        "storage": .object([
                            "type": .string("string"),
                            "description": .string("Optional storage location name or path")
                        ]),
                        "include_password": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, return the unredacted `vnc://:password@host:port` URL. Defaults to false. The password may end up in MCP transport logs; only enable in trusted contexts.")
                        ])
                    ]),
                    "required": .array([.string("name")])
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
            case "lume_pull_status":
                return try await handlePullStatus(params.arguments)
            case "lume_screen_capture":
                return try await handleScreenCapture(params.arguments)
            case "lume_screen_click":
                return try await handleScreenClick(params.arguments)
            case "lume_screen_type":
                return try await handleScreenType(params.arguments)
            case "lume_screen_paste":
                return try await handleScreenPaste(params.arguments)
            case "lume_put_file":
                return try await handlePutFile(params.arguments)
            case "lume_get_file":
                return try await handleGetFile(params.arguments)
            case "lume_host_status":
                return try await handleHostStatus(params.arguments)
            case "lume_open_vnc":
                return try await handleOpenVNC(params.arguments)
            case "lume_wait_for_vm":
                return try await handleWaitForVM(params.arguments)
            case "lume_snapshot_create":
                return try await handleSnapshotCreate(params.arguments)
            case "lume_snapshot_list":
                return try await handleSnapshotList(params.arguments)
            case "lume_snapshot_restore":
                return try await handleSnapshotRestore(params.arguments)
            case "lume_snapshot_delete":
                return try await handleSnapshotDelete(params.arguments)
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
        let includeSnapshots = args?["include_snapshots"]?.boolValue ?? false
        var vms = try controller.list(storage: storage)
        if !includeSnapshots {
            // Hide snapshots — they have a structural name shape '<vm>__snap__<id>'.
            // Use lume_snapshot_list for a structured view of one VM's snapshots.
            vms = vms.filter { !$0.name.contains(Self.snapshotSeparator) }
        }
        // Re-serialize via Codable then parse back to [Any] so the envelope's
        // JSONSerialization-based payload can include the structured VM list.
        let encoded = try JSONEncoder().encode(vms)
        let asArray = (try JSONSerialization.jsonObject(with: encoded) as? [Any]) ?? []
        return MCPResponse.success(operation: "list_vms", resultArray: asArray)
    }

    /// Naming convention for snapshots: a snapshot of VM "foo" with id "bar" is stored
    /// as VM "foo__snap__bar". Brittle if a user happens to give a real VM that name,
    /// but documented; saves us from adding a sidecar database.
    private static let snapshotSeparator = "__snap__"

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
        let sourceStorage = args?["source_storage"]?.stringValue
        let destStorage = args?["dest_storage"]?.stringValue

        try controller.clone(
            name: name,
            newName: newName,
            sourceLocation: sourceStorage,
            destLocation: destStorage ?? sourceStorage
        )
        var result: [String: Any] = ["source": name, "name": newName]
        if let s = sourceStorage { result["source_storage"] = s }
        if let d = destStorage { result["dest_storage"] = d }
        return MCPResponse.success(
            operation: "clone_vm",
            result: result,
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

    private func handlePullStatus(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "pull_status", code: "validation_error", message: "'name' is required")
        }

        let progress = await PullProgressTracker.shared.getProgress(for: name)
        let errorMsg = await PullProgressTracker.shared.getError(for: name)
        let isPulling = await PullProgressTracker.shared.isPulling(name)

        var result: [String: Any] = ["name": name]
        if let p = progress {
            result["state"] = "pulling"
            result["progress"] = p              // 0.0–1.0
            result["progress_percent"] = Int(p * 100)
        } else if let err = errorMsg {
            result["state"] = "error"
            result["error"] = err
        } else if isPulling {
            // Edge: tracker started but progress not set yet (very early in the call).
            result["state"] = "pulling"
            result["progress"] = 0.0
            result["progress_percent"] = 0
        } else {
            // Either not started, or completed and the tracker has cleared.
            result["state"] = "not_pulling"
        }
        return MCPResponse.success(operation: "pull_status", result: result)
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

    /// Returns the noVNC viewer URL for a running VM. The user (or the agent
    /// on their behalf) can `open <url>` to get a full interactive desktop
    /// in a browser. For programmatic screen access, prefer lume_screen_capture
    /// rather than driving the WebSocket bridge.
    ///
    /// We surface both the browser URL (`/vnc/<name>`) and the WebSocket URL
    /// (`/vnc/<name>/ws`), plus the native `vnc://` URL for users who'd
    /// rather use Screen Sharing.app or a dedicated VNC client.
    private func handleOpenVNC(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(
                operation: "open_vnc",
                code: "validation_error",
                message: "'name' is required"
            )
        }
        let storage = args?["storage"]?.stringValue
        let includePassword = args?["include_password"]?.boolValue ?? false

        let vm = try controller.getDetails(name: name, storage: storage)
        return Self.buildOpenVNCResult(name: name, vm: vm, includePassword: includePassword)
    }

    /// Pure helper: produce an open_vnc envelope from a known VMDetails.
    /// Extracted from `handleOpenVNC` so error paths (and the password
    /// redaction logic) can be unit-tested without a running controller.
    /// nonisolated so callers don't have to hop to MainActor just to read
    /// fields off a Sendable Codable value.
    nonisolated static func buildOpenVNCResult(
        name: String,
        vm: VMDetails,
        includePassword: Bool
    ) -> CallTool.Result {
        guard vm.status == "running" else {
            return MCPResponse.error(
                operation: "open_vnc",
                code: "vnc_unavailable",
                message: "VM '\(name)' is not running (status: \(vm.status))"
            )
        }
        guard let nativeVNCURL = vm.vncUrl else {
            return MCPResponse.error(
                operation: "open_vnc",
                code: "vnc_unavailable",
                message: "VM '\(name)' has no VNC URL"
            )
        }

        // The HTTP daemon's port. The MCP server runs in-process with the
        // daemon's binary, but as a separate `bushel serve --mcp` invocation;
        // it doesn't know the HTTP server's port. 7777 is the default and
        // is honored by both the LaunchAgent installer and the dashboard.
        // BUSHEL_DAEMON_PORT can override for non-default deployments.
        let port = ProcessInfo.processInfo.environment["BUSHEL_DAEMON_PORT"].flatMap { UInt16($0) } ?? 7777

        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let browserURL = "http://127.0.0.1:\(port)/vnc/\(encodedName)"
        let wsURL = "ws://127.0.0.1:\(port)/vnc/\(encodedName)/ws"

        // Redact the userinfo (`:password@`) from native_vnc_url by default.
        // The cleartext password may otherwise land in MCP transport logs.
        // Callers that need the full URL can opt in via include_password.
        let nativeVNCResponseURL = includePassword
            ? nativeVNCURL
            : redactVNCURLPassword(nativeVNCURL)

        return MCPResponse.success(
            operation: "open_vnc",
            result: [
                "name": name,
                "url": browserURL,
                "ws_url": wsURL,
                "native_vnc_url": nativeVNCResponseURL,
            ],
            message: "Open \(browserURL) in a browser, or use a native VNC viewer with \(nativeVNCResponseURL)."
        )
    }

    /// Strip the `:password@` userinfo from a `vnc://[user]:[password]@host:port`
    /// URL. Returns the input unchanged if it doesn't parse as a URL (defensive
    /// — the daemon should always hand us a well-formed vncUrl, but a bad
    /// upstream change shouldn't surface the password just because parsing
    /// failed).
    nonisolated static func redactVNCURLPassword(_ urlString: String) -> String {
        // URLComponents doesn't accept "vnc://"; reuse the same http:// trick
        // that parseVNCEndpoint uses for the bridge side.
        let httpish = urlString.replacingOccurrences(of: "vnc://", with: "http://")
        guard var comps = URLComponents(string: httpish) else { return urlString }
        comps.user = nil
        comps.password = nil
        guard let redactedHttpish = comps.string else { return urlString }
        return redactedHttpish.replacingOccurrences(of: "http://", with: "vnc://")
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

    // MARK: - Snapshots
    //
    // Backed by lume's existing clone() (which uses APFS clonefile() under the hood,
    // so disk.img is duplicated near-instantly with copy-on-write semantics — the
    // snapshot's storage cost grows only as it diverges from the source). The naming
    // convention <vm>__snap__<name> hides snapshots from lume_list_vms by default
    // and is parsed in lume_snapshot_list for structured output.
    //
    // Limitation: clone() requires the source VM to be stopped, so snapshot/restore
    // require a stop+start cycle around them. Live snapshots would need a quiesced
    // disk-state hook the Apple Virtualization.framework doesn't expose.

    private func handleSnapshotCreate(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let vm = args?["vm"]?.stringValue else {
            return MCPResponse.error(operation: "snapshot_create", code: "validation_error", message: "'vm' is required")
        }
        guard let name = args?["name"]?.stringValue, !name.isEmpty else {
            return MCPResponse.error(operation: "snapshot_create", code: "validation_error", message: "'name' is required and must be non-empty")
        }
        guard !name.contains(Self.snapshotSeparator) else {
            return MCPResponse.error(
                operation: "snapshot_create",
                code: "validation_error",
                message: "Snapshot name must not contain '\(Self.snapshotSeparator)'"
            )
        }

        let snapshotVMName = "\(vm)\(Self.snapshotSeparator)\(name)"
        try controller.clone(name: vm, newName: snapshotVMName)

        return MCPResponse.success(
            operation: "snapshot_create",
            result: ["vm": vm, "snapshot": name, "snapshot_vm": snapshotVMName],
            message: "Snapshot '\(name)' created for VM '\(vm)'."
        )
    }

    private func handleSnapshotList(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let vm = args?["vm"]?.stringValue else {
            return MCPResponse.error(operation: "snapshot_list", code: "validation_error", message: "'vm' is required")
        }

        let prefix = "\(vm)\(Self.snapshotSeparator)"
        let allVMs = try controller.list(storage: nil)
        let snapshots: [[String: Any]] = allVMs
            .filter { $0.name.hasPrefix(prefix) }
            .map { details in
                let snapName = String(details.name.dropFirst(prefix.count))
                return [
                    "name": snapName,
                    "snapshot_vm": details.name,
                    "status": details.status,
                    "os": details.os,
                    "location": details.locationName,
                ]
            }

        return MCPResponse.success(
            operation: "snapshot_list",
            result: ["vm": vm, "snapshots": snapshots, "count": snapshots.count]
        )
    }

    private func handleSnapshotRestore(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let vm = args?["vm"]?.stringValue else {
            return MCPResponse.error(operation: "snapshot_restore", code: "validation_error", message: "'vm' is required")
        }
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "snapshot_restore", code: "validation_error", message: "'name' is required")
        }

        let snapshotVMName = "\(vm)\(Self.snapshotSeparator)\(name)"

        // Snapshot must exist; surface vm_not_found rather than letting clone() fail
        // halfway through (after we've already deleted the original VM).
        do {
            _ = try controller.get(name: snapshotVMName)
        } catch {
            return MCPResponse.error(
                operation: "snapshot_restore",
                code: "vm_not_found",
                message: "Snapshot '\(name)' not found for VM '\(vm)' (looked for '\(snapshotVMName)')"
            )
        }

        // Delete current VM if it exists. We swallow not-found errors — the user may
        // be restoring into a slot where the VM was already deleted.
        do {
            try await controller.delete(name: vm, storage: nil)
        } catch {
            if MCPResponse.errorCode(for: error) != "vm_not_found" {
                throw error
            }
        }

        // Clone snapshot back to the original name. APFS clonefile = ~instant.
        try controller.clone(name: snapshotVMName, newName: vm)

        return MCPResponse.success(
            operation: "snapshot_restore",
            result: ["vm": vm, "snapshot": name, "from": snapshotVMName],
            message: "VM '\(vm)' restored from snapshot '\(name)'."
        )
    }

    private func handleSnapshotDelete(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let vm = args?["vm"]?.stringValue else {
            return MCPResponse.error(operation: "snapshot_delete", code: "validation_error", message: "'vm' is required")
        }
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "snapshot_delete", code: "validation_error", message: "'name' is required")
        }

        let snapshotVMName = "\(vm)\(Self.snapshotSeparator)\(name)"
        try await controller.delete(name: snapshotVMName, storage: nil)

        return MCPResponse.success(
            operation: "snapshot_delete",
            result: ["vm": vm, "snapshot": name, "snapshot_vm": snapshotVMName],
            message: "Snapshot '\(name)' deleted for VM '\(vm)'."
        )
    }

    // MARK: - Screen tools (capture / click / type / paste)
    //
    // Each tool spins up a fresh VNCClient against the VM's vncUrl, runs the
    // RFB protocol exchange, and tears down. Per-call connect is fine for
    // one-shot operations like a screen capture or a few keystrokes; for very
    // long type/paste sessions a connection-cache could shave handshake time
    // (~100ms per call), but that's an optimization the LLM doesn't care
    // about for the typical agent loop.

    /// Resolves a VM's vncUrl into a connected, post-handshake VNCClient.
    /// `vnc://:PASSWORD@HOST:PORT` is parsed via URLComponents after a
    /// scheme swap to http (vnc isn't a registered scheme).
    private func openVNC(forVM name: String, storage: String?) async throws -> VNCClient {
        let vm = try controller.getDetails(name: name, storage: storage)
        guard vm.status == "running" else {
            throw VMError.notRunning(name)
        }
        guard let urlString = vm.vncUrl else {
            throw VMError.vncNotConfigured
        }
        let httpish = urlString.replacingOccurrences(of: "vnc://", with: "http://")
        guard let comps = URLComponents(string: httpish),
              let host = comps.host,
              let port = comps.port,
              let password = comps.password,
              port >= 0, port <= 65535
        else {
            throw VMError.internalError("Could not parse vncUrl: \(urlString)")
        }
        let client = VNCClient(host: host, port: UInt16(port), password: password)
        try await client.connect()
        try await client.handshake()
        return client
    }

    private func handleScreenCapture(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "screen_capture", code: "validation_error", message: "'name' is required")
        }
        let storage = args?["storage"]?.stringValue
        let client = try await openVNC(forVM: name, storage: storage)
        let cgImage = try await client.captureFramebuffer()

        // CGImage -> PNG via NSBitmapImageRep (AppKit). Same path the unattended
        // OCR layer uses internally; reliable on the runner used by tests/CI.
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            return MCPResponse.error(operation: "screen_capture", code: "internal_error", message: "Failed to encode framebuffer as PNG")
        }
        let base64 = pngData.base64EncodedString()

        // Return BOTH an MCP image content item AND the standard JSON envelope
        // sidecar so vision agents see the image inline while non-vision agents
        // can still read the metadata (width/height/byte size).
        let envelope: [String: Any] = [
            "ok": true,
            "operation": "screen_capture",
            "result": [
                "name": name,
                "width": cgImage.width,
                "height": cgImage.height,
                "size_bytes": pngData.count,
                "format": "image/png",
            ],
            "message": "Captured \(cgImage.width)x\(cgImage.height) PNG (\(pngData.count) bytes) from '\(name)'.",
        ]
        let envelopeData = (try? JSONSerialization.data(
            withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let envelopeText = String(data: envelopeData, encoding: .utf8) ?? "{}"

        return CallTool.Result(
            content: [
                .image(data: base64, mimeType: "image/png", annotations: nil, _meta: nil),
                .text(envelopeText),
            ],
            isError: false
        )
    }

    private func handleScreenClick(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "screen_click", code: "validation_error", message: "'name' is required")
        }
        guard let x = args?["x"]?.intValue, let y = args?["y"]?.intValue else {
            return MCPResponse.error(operation: "screen_click", code: "validation_error", message: "'x' and 'y' are required (integer pixel coords)")
        }
        guard x >= 0, y >= 0, x <= Int(UInt16.max), y <= Int(UInt16.max) else {
            return MCPResponse.error(operation: "screen_click", code: "validation_error", message: "x and y must be non-negative and fit in UInt16 (0..65535)")
        }

        let buttonStr = (args?["button"]?.stringValue ?? "left").lowercased()
        let buttonMask: UInt8
        switch buttonStr {
        case "left": buttonMask = VNCMouseButton.left.rawValue
        case "middle": buttonMask = VNCMouseButton.middle.rawValue
        case "right": buttonMask = VNCMouseButton.right.rawValue
        default:
            return MCPResponse.error(operation: "screen_click", code: "validation_error", message: "'button' must be 'left', 'middle', or 'right'")
        }

        let double = args?["double"]?.boolValue ?? false
        let storage = args?["storage"]?.stringValue
        let client = try await openVNC(forVM: name, storage: storage)
        let xu = UInt16(x), yu = UInt16(y)

        // Move first (helps some guests register the click), then press/release.
        // Timing mirrors VNCService.sendMouseClick — proven on macOS guests.
        try await client.sendPointerEvent(x: xu, y: yu, buttonMask: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await client.sendPointerEvent(x: xu, y: yu, buttonMask: buttonMask)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await client.sendPointerEvent(x: xu, y: yu, buttonMask: 0)

        if double {
            try await Task.sleep(nanoseconds: 100_000_000)
            try await client.sendPointerEvent(x: xu, y: yu, buttonMask: buttonMask)
            try await Task.sleep(nanoseconds: 100_000_000)
            try await client.sendPointerEvent(x: xu, y: yu, buttonMask: 0)
        }

        return MCPResponse.success(
            operation: "screen_click",
            result: ["name": name, "x": x, "y": y, "button": buttonStr, "double": double],
            message: "Clicked at (\(x), \(y)) on '\(name)'\(double ? " (double)" : "")."
        )
    }

    private func handleScreenType(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "screen_type", code: "validation_error", message: "'name' is required")
        }
        guard let text = args?["text"]?.stringValue else {
            return MCPResponse.error(operation: "screen_type", code: "validation_error", message: "'text' is required")
        }
        let delayMs = args?["delay_ms"]?.intValue ?? 50
        let storage = args?["storage"]?.stringValue
        let client = try await openVNC(forVM: name, storage: storage)

        let delayNs = UInt64(max(0, delayMs)) * 1_000_000

        // Reuses the top-level charToKeysym(_:) helper from src/VNC/X11Keysyms.swift
        // so MCP and VNCService send the exact same sequence for a given character.
        for char in text {
            if char == "\n" {
                // Send Return as a real key press, not a literal '\n' keysym.
                try await client.sendKeyEvent(key: X11Keysym.returnKey.rawValue, down: true)
                try await client.sendKeyEvent(key: X11Keysym.returnKey.rawValue, down: false)
            } else {
                let (keysym, needsShift) = charToKeysym(char)
                if needsShift {
                    try await client.sendKeyEvent(key: X11Keysym.shiftL.rawValue, down: true)
                }
                try await client.sendKeyEvent(key: keysym, down: true)
                try await client.sendKeyEvent(key: keysym, down: false)
                if needsShift {
                    try await client.sendKeyEvent(key: X11Keysym.shiftL.rawValue, down: false)
                }
            }
            if delayNs > 0 {
                try await Task.sleep(nanoseconds: delayNs)
            }
        }

        return MCPResponse.success(
            operation: "screen_type",
            result: ["name": name, "characters": text.count, "delay_ms": delayMs],
            message: "Typed \(text.count) characters into '\(name)'."
        )
    }

    // MARK: - File transfer
    //
    // SSH-based, no extra system tools. Encodes file contents as base64 and
    // pipes through `base64 -d` / `base64` on the guest, riding the existing
    // SSHClient.execute() one-shot command. Hard-capped at 10 MB per call
    // because SSHResult.output buffers the whole response in memory.

    private static let fileTransferMaxBytes = 10 * 1024 * 1024  // 10 MB

    private func handlePutFile(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "put_file", code: "validation_error", message: "'name' is required")
        }
        guard let hostPath = args?["host_path"]?.stringValue else {
            return MCPResponse.error(operation: "put_file", code: "validation_error", message: "'host_path' is required")
        }
        guard let vmPath = args?["vm_path"]?.stringValue else {
            return MCPResponse.error(operation: "put_file", code: "validation_error", message: "'vm_path' is required")
        }
        let user = args?["user"]?.stringValue ?? "lume"
        let password = args?["password"]?.stringValue ?? "lume"
        let storage = args?["storage"]?.stringValue

        let vm = try controller.get(name: name, storage: storage)
        guard let ip = vm.details.ipAddress else {
            return MCPResponse.error(operation: "put_file", code: "vm_not_running", message: "VM '\(name)' has no IP address. Is it running?")
        }

        let expandedPath = (hostPath as NSString).expandingTildeInPath
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: expandedPath))
        } catch {
            return MCPResponse.error(operation: "put_file", code: "file_not_found", message: "Could not read host file '\(hostPath)': \(error.localizedDescription)")
        }
        if data.count > Self.fileTransferMaxBytes {
            return MCPResponse.error(
                operation: "put_file",
                code: "file_too_large",
                message: "File is \(data.count) bytes; max \(Self.fileTransferMaxBytes) for lume_put_file. Mount a shared_dir at lume_start_vm for larger transfers."
            )
        }

        let base64 = data.base64EncodedString()
        // Single-quote-escape vmPath so spaces / metachars don't break the shell.
        let safeVMPath = vmPath.replacingOccurrences(of: "'", with: "'\\''")
        // `base64 -d` reads stdin; the `<<<` here-string keeps the entire payload
        // off the argv (which has length limits) while still being a single shell
        // command compatible with the SSH exec channel.
        let cmd = "base64 -d <<< '\(base64)' > '\(safeVMPath)'"

        let sshClient = SSHClient(host: ip, port: 22, user: user, password: password)
        let result = try await sshClient.execute(command: cmd, timeout: 120)
        guard result.exitCode == 0 else {
            return MCPResponse.error(
                operation: "put_file",
                code: "command_failed",
                message: "Failed to write '\(vmPath)': \(result.output.isEmpty ? "exit \(result.exitCode)" : result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return MCPResponse.success(
            operation: "put_file",
            result: ["name": name, "host_path": hostPath, "vm_path": vmPath, "size_bytes": data.count],
            message: "Wrote \(data.count) bytes to '\(vmPath)' on '\(name)'."
        )
    }

    private func handleGetFile(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "get_file", code: "validation_error", message: "'name' is required")
        }
        guard let vmPath = args?["vm_path"]?.stringValue else {
            return MCPResponse.error(operation: "get_file", code: "validation_error", message: "'vm_path' is required")
        }
        guard let hostPath = args?["host_path"]?.stringValue else {
            return MCPResponse.error(operation: "get_file", code: "validation_error", message: "'host_path' is required")
        }
        let user = args?["user"]?.stringValue ?? "lume"
        let password = args?["password"]?.stringValue ?? "lume"
        let storage = args?["storage"]?.stringValue

        let vm = try controller.get(name: name, storage: storage)
        guard let ip = vm.details.ipAddress else {
            return MCPResponse.error(operation: "get_file", code: "vm_not_running", message: "VM '\(name)' has no IP address. Is it running?")
        }

        let safeVMPath = vmPath.replacingOccurrences(of: "'", with: "'\\''")
        // wc -c first so we can refuse oversized files before pulling all bytes.
        let sshClient = SSHClient(host: ip, port: 22, user: user, password: password)
        let sizeResult = try await sshClient.execute(
            command: "wc -c < '\(safeVMPath)' 2>/dev/null || echo MISSING", timeout: 30)
        let sizeStr = sizeResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if sizeStr == "MISSING" || sizeResult.exitCode != 0 {
            return MCPResponse.error(operation: "get_file", code: "file_not_found", message: "VM file '\(vmPath)' not readable")
        }
        if let bytes = Int(sizeStr), bytes > Self.fileTransferMaxBytes {
            return MCPResponse.error(
                operation: "get_file",
                code: "file_too_large",
                message: "File is \(bytes) bytes; max \(Self.fileTransferMaxBytes) for lume_get_file. Mount a shared_dir for larger transfers."
            )
        }

        let result = try await sshClient.execute(command: "base64 < '\(safeVMPath)'", timeout: 120)
        guard result.exitCode == 0 else {
            return MCPResponse.error(
                operation: "get_file",
                code: "command_failed",
                message: "Failed to read '\(vmPath)': \(result.output.isEmpty ? "exit \(result.exitCode)" : result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }

        // base64 output may be wrapped (BSD base64 wraps at 76 cols); strip whitespace.
        let stripped = result.output.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: stripped) else {
            return MCPResponse.error(operation: "get_file", code: "internal_error", message: "Could not decode base64 output from VM")
        }

        let expandedPath = (hostPath as NSString).expandingTildeInPath
        do {
            try data.write(to: URL(fileURLWithPath: expandedPath))
        } catch {
            return MCPResponse.error(operation: "get_file", code: "internal_error", message: "Could not write host file '\(hostPath)': \(error.localizedDescription)")
        }

        return MCPResponse.success(
            operation: "get_file",
            result: ["name": name, "vm_path": vmPath, "host_path": hostPath, "size_bytes": data.count],
            message: "Read \(data.count) bytes from '\(vmPath)' on '\(name)' -> '\(hostPath)'."
        )
    }

    private func handleScreenPaste(_ args: [String: Value]?) async throws -> CallTool.Result {
        guard let name = args?["name"]?.stringValue else {
            return MCPResponse.error(operation: "screen_paste", code: "validation_error", message: "'name' is required")
        }
        guard let text = args?["text"]?.stringValue else {
            return MCPResponse.error(operation: "screen_paste", code: "validation_error", message: "'text' is required")
        }
        let storage = args?["storage"]?.stringValue

        // Write to the host pasteboard. ClipboardWatcher (if running for this VM)
        // syncs to the guest within ~1s. If the user's VM was started without
        // clipboard:true, this path won't deliver the text — agents that hit
        // 'paste does nothing' should fall back to lume_screen_type.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the clipboard sync 1.2s to propagate before we send Cmd+V.
        // Empirically reliable; lower values race with the watcher's poll cycle.
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let client = try await openVNC(forVM: name, storage: storage)
        // Cmd+V on macOS guests: OSXvnc maps X11 Alt to macOS Command (per the
        // VNCService.sendCharWithModifiers comments). 'V' is unshifted v + Shift,
        // but for Cmd+V we just send the lowercase v keysym + the Cmd modifier.
        let vKey = charToKeysym("v").keysym
        try await client.sendKeyEvent(key: X11Keysym.altL.rawValue, down: true)  // = Command on guest
        try await client.sendKeyEvent(key: vKey, down: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        try await client.sendKeyEvent(key: vKey, down: false)
        try await client.sendKeyEvent(key: X11Keysym.altL.rawValue, down: false)

        return MCPResponse.success(
            operation: "screen_paste",
            result: ["name": name, "characters": text.count],
            message: "Wrote \(text.count) chars to host pasteboard and sent Cmd+V to '\(name)'. If the VM wasn't started with clipboard sync enabled, fall back to lume_screen_type."
        )
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
