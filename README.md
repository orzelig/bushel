# Bushel

CLI and framework for macOS and Linux VMs using Apple Virtualization Framework. Apple Silicon only.

## What is bushel?

Bushel is a maintained fork of [lume](https://github.com/trycua/cua/tree/main/libs/lume), extracted from the [trycua/cua](https://github.com/trycua/cua) monorepo via `git filter-repo --subdirectory-filter libs/lume` (history preserved). It carries fixes ahead of upstream:

- [trycua/cua#1395](https://github.com/trycua/cua/pull/1395) — `pull macos-*` now correctly assembles 21 GB OCI tar-part disk images
- [trycua/cua#1441](https://github.com/trycua/cua/pull/1441) — `create --unattended` Tahoe preset works on macOS 26's renamed Setup Assistant buttons

See [UPSTREAM-STATUS.md](UPSTREAM-STATUS.md) for the full relationship to upstream — provenance, vendored PRs, and open PRs under evaluation.

## Install

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/install.sh)"
```

Installs the `bushel` binary to `~/.local/bin/bushel` and registers a LaunchAgent (`dev.orzelig.bushel.daemon`) for `bushel serve` on `127.0.0.1:7777`. Apple Silicon only. No telemetry, no auto-update by default.

To uninstall: `bash <(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/uninstall.sh)`. User data in `~/.lume` and `~/.config/lume` is preserved unless you pass `--purge`.

### Build from source

```bash
swift build -c release
.build/arm64-apple-macosx/release/bushel --help
```

## Use with Claude

After installing:

```bash
bushel claude-setup
```

This detects Claude Desktop and Claude Code on your machine, registers bushel as an MCP server in each, and tells you to restart the client. Then tell Claude:

> Start using bushel.

That's it. Claude can now drive bushel's 10 MCP tools (list/get/start/stop/clone/delete/exec/create VMs, plus pull-image and host-status).

`claude-setup` is idempotent — re-running it is a safe no-op when the config is already correct. Use `--dry-run` to see what it would change, or `--print-only` to get the Claude Desktop config snippet without writing files.

## Compatibility with lume

Bushel renames only the binary. Everything else is wire-compatible with lume:

- **Daemon endpoint**: `127.0.0.1:7777`, same HTTP routes (`/lume/vms`, `/lume/pull`, …) — existing dashboards and scripts work unchanged
- **Data layout**: VMs in `~/.lume/`, config in `~/.config/lume/` — switching from lume to bushel finds your existing VMs
- **MCP tools**: `lume_list_vms`, `lume_create_vm`, … — AI clients with cached tool names keep working
- **Image registry**: bushel reads and writes images with `org.trycua.lume.*` OCI annotations — fully interoperable with images pushed by lume
- **VM credentials**: default `lume`/`lume` user inside unattended-built VMs (these are baked into the VM image, not the binary)

You can run lume and bushel side by side; their LaunchAgent labels differ (`com.trycua.lume_daemon` vs `dev.orzelig.bushel.daemon`), but they'll fight over port 7777 — only run one daemon at a time.

## Documentation

**[Upstream lume documentation](https://cua.ai/docs/lume)** — installation guides, CLI reference, and architecture. Bushel is CLI-compatible; substitute `bushel` for `lume` in command examples.

## Relationship to upstream

Bushel is a maintained fork. We track upstream lume and pull in important developments — bug fixes and meaningful improvements — as they appear. The fork is here to stay: bushel ships fixes ahead of upstream's review cadence, and we'll keep doing so. If upstream merges a PR we've already vendored, the bushel commit reconciles to a no-op rebase.

For the current vendored set, open PRs under evaluation, and known unaddressed issues, see [UPSTREAM-STATUS.md](UPSTREAM-STATUS.md). For bushel-specific bugs, file an [issue](https://github.com/orzelig/bushel/issues) on this repo; for bugs that exist upstream too, please cross-link the upstream issue.
