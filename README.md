```
 ██████╗ ██╗   ██╗███████╗██╗  ██╗███████╗██╗
 ██╔══██╗██║   ██║██╔════╝██║  ██║██╔════╝██║
 ██████╔╝██║   ██║███████╗███████║█████╗  ██║
 ██╔══██╗██║   ██║╚════██║██╔══██║██╔══╝  ██║
 ██████╔╝╚██████╔╝███████║██║  ██║███████╗███████╗
 ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝
```

<p align="center"><strong>Apple Silicon macOS &amp; Linux VMs — fully drivable by AI agents over MCP.</strong></p>

<p align="center">
  <a href="LICENSE.md"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-yellow.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%20arm64-blue">
  <a href="https://github.com/orzelig/bushel/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/orzelig/bushel"></a>
  <a href="https://orzelig.github.io/givebackai/"><img alt="GiveBackAI partner" src="https://img.shields.io/badge/contribute%20via-GiveBackAI-7057ff"></a>
</p>

---

Bushel is a Swift CLI + daemon for spinning up macOS and Linux VMs on Apple Silicon. What makes it different: **24 MCP tools** that let Claude (or any MCP client) drive a VM end-to-end — start, snapshot, exec a shell, see the screen, click, type. A maintained fork of [lume](https://github.com/trycua/cua/tree/main/libs/lume) carrying fixes ahead of upstream.

## Quick start

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/install.sh)"
```

Installs `bushel` to `~/.local/bin`, registers a LaunchAgent serving the daemon on `127.0.0.1:7777`, and exits. No telemetry. No cloud. Apple Silicon only.

Verify:

```bash
bushel host-status                  # confirms daemon is up + Virtualization.framework available
open http://127.0.0.1:7777/         # web dashboard
```

Pull and start a macOS VM:

```bash
bushel pull macos-sequoia-vanilla:latest my-vm
bushel start my-vm
```

> [!TIP]
> **Have Claude Code open?** Skip the install command. Just tell Claude:
>
> > Install bushel from https://github.com/orzelig/bushel — read INSTALL_FOR_CLAUDE.md first.
>
> Claude will fetch [INSTALL_FOR_CLAUDE.md](INSTALL_FOR_CLAUDE.md), run the installer, and wire bushel into itself as an MCP server in one step. Restart Claude and say *"Start using bushel."*

## What you get

| | |
|---|---|
| **CLI** | `bushel create / clone / start / stop / exec / pull / snapshot / set …` — full lume CLI, plus extras |
| **Local daemon** | LaunchAgent on `127.0.0.1:7777`. Loopback-only. Restart-safe |
| **Web dashboard** | Open the daemon URL. List, create, clone, edit metadata, watch pull progress, start/stop. Refreshes every 5s |
| **Browser VNC** | `http://127.0.0.1:7777/vnc/<name>` — [noVNC](https://github.com/novnc/noVNC) viewer with clipboard bridge. No Screen Sharing.app |
| **MCP server** | 24 tools for AI agents: lifecycle, snapshots, file transfer, **screen capture / click / type / paste**, exec, pull |
| **Snapshots & clones** | APFS copy-on-write — almost free. Safe "snapshot + clone" pattern for iterating on Setup Assistant automation |
| **Per-VM metadata** | Creator / description / owner annotations stored sidecar-style, editable in the dashboard |
| **Auto-update** | Opt-in. Daily check, notification on availability, SHA-256 verification, codesigned binary, never auto-applies |

## Use with AI

The MCP integration is one command:

```bash
bushel claude-setup
```

Detects Claude Desktop and Claude Code on your machine, registers bushel as an MCP server in each. Idempotent. Use `--dry-run` to preview, `--print-only` for a manual-paste snippet.

Restart Claude, then say *"Start using bushel."* Claude can now:

- **Manage** VMs — list, get info, create, clone, delete, start, stop, wait-for-boot
- **Pull** macOS or Linux images from the OCI registry (with progress polling)
- **Exec** shell commands in a running guest, get stdout/stderr/exit
- **Transfer files** in and out via `lume_get_file` / `lume_put_file`
- **Snapshot** before risky changes, restore on failure — fully scriptable
- **Drive the GUI** — `lume_screen_capture` (PNG of the desktop), `lume_screen_click` (x,y or by image template), `lume_screen_type`, `lume_screen_paste`
- **Open VNC** — `lume_open_vnc` returns the noVNC URL for a human to look at

That last cluster is what makes bushel different from upstream lume: an AI agent can *see* and *interact with* the VM screen, not just shell into it.

## Cheat sheet

```bash
bushel list                                    # all VMs
bushel pull macos-tahoe-vanilla:latest tahoe   # download image
bushel create my-vm --os macos --ipsw latest --unattended
bushel start my-vm                             # boot in background
bushel exec my-vm "sw_vers"                    # run command in guest
bushel snapshot create my-vm before-test       # cheap APFS snapshot
bushel clone my-vm experiment-1                # COW clone
bushel set my-vm --disk-size 200               # grow disk (in GB)
bushel stop my-vm                              # graceful shutdown
bushel delete experiment-1                     # remove a VM
bushel update                                  # upgrade bushel itself
bushel update --check-only                     # just check, no swap
```

Default credentials in unattended-built VMs: **`lume` / `lume`** (baked into the image, not the binary).

Build from source:

```bash
swift build -c release
.build/arm64-apple-macosx/release/bushel --help
```

Menu-bar status icon (open dashboard, see VM count, start/stop daemon): pass `--menubar` to `install.sh`. Uninstall: `bash <(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/uninstall.sh)` — `--purge` also deletes `~/.lume` data.

## Compatibility with lume

Bushel renames the binary only. Everything else is wire-compatible:

| | bushel | upstream lume |
|---|---|---|
| Daemon port | `127.0.0.1:7777` | same |
| HTTP routes | `/lume/vms`, `/lume/pull`, … | same |
| Data layout | `~/.lume/`, `~/.config/lume/` | same |
| MCP tool names | `lume_*` | same |
| Image registry | OCI w/ `org.trycua.lume.*` annotations | same |
| LaunchAgent label | `io.github.orzelig.bushel.daemon` | `com.trycua.lume_daemon` |

Switching to bushel finds your existing lume VMs. Side-by-side install works, but only one daemon can hold port 7777 — disable lume's LaunchAgent first.

## Contributing

Bushel is a partner on [**GiveBackAI**](https://orzelig.github.io/givebackai/) — you can donate unused Claude quota to fix bushel issues. Browse [issues labeled `givebackai-ready`](https://github.com/orzelig/bushel/issues?q=is%3Aopen+label%3Agivebackai-ready) for self-contained picks.

For bugs and feature requests: open an [issue](https://github.com/orzelig/bushel/issues). For local development: [CONTRIBUTING.md](CONTRIBUTING.md) and [Development.md](Development.md).

## Documentation

- **[INSTALL_FOR_CLAUDE.md](INSTALL_FOR_CLAUDE.md)** — what Claude reads when you ask it to install bushel
- **[UPSTREAM-STATUS.md](UPSTREAM-STATUS.md)** — vendored PRs, evaluation candidates, known divergences
- **[Development.md](Development.md)** — local dev setup
- **[Upstream lume docs](https://cua.ai/docs/lume)** — bushel is CLI-compatible; substitute `bushel` for `lume`

## Relationship to upstream

Bushel is a maintained fork. We track upstream lume and pull in important developments — bug fixes and meaningful improvements — as they appear. Bushel ships fixes ahead of upstream's review cadence. If upstream merges a PR we've already vendored, the bushel commit reconciles to a no-op rebase. For the current vendored set and open evaluations, see [UPSTREAM-STATUS.md](UPSTREAM-STATUS.md).

## License

MIT — see [LICENSE.md](LICENSE.md). Copyright © 2025 Cua AI, Inc. Bushel modifications are also MIT.
