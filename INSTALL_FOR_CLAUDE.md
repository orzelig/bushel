# Install bushel — instructions for Claude

You (Claude) are reading this because a user asked you to install bushel for them. This file is the canonical install procedure. Follow it exactly.

## What bushel is

Bushel is a CLI and daemon for managing macOS / Linux VMs on Apple Silicon, with a 22-tool MCP server purpose-built for AI agents. It's a maintained fork of [trycua/cua/libs/lume](https://github.com/trycua/cua/tree/main/libs/lume).

## Prerequisites (verify before installing)

- macOS host on Apple Silicon (`uname -sm` should print `Darwin arm64`)
- The user is not running as root (no `sudo`)
- `curl`, `tar`, `launchctl`, `plutil` available (all standard on macOS)

If any prereq fails, stop and tell the user.

## Install

Run this in the user's shell via your Bash tool:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/install.sh)"
```

Default behavior:
- Downloads the latest release tarball, verifies it's a valid `tar.gz`
- Installs `bushel` → `~/.local/bin/bushel`
- Registers a daemon LaunchAgent on `127.0.0.1:7777` (wire-compatible with lume)
- Registers a daily update-check LaunchAgent (10:00 local time, surfaces a notification — never auto-applies)

Optional flags worth knowing:
- `--port 7778` — use a different daemon port if 7777 is in use (e.g., the user already runs lume)
- `--menubar` — also install `bushel-bar`, the macOS menu bar app
- `--no-auto-update-check` — skip the daily update LaunchAgent
- `--install-dir <DIR>` — override `~/.local/bin`

If port 7777 is already in use (lume daemon, etc.), pass `--port 7778` and warn the user that bushel is on the alternate port.

## After install: wire bushel into yourself

If you're Claude Code (you have a Bash tool), run this immediately so the user doesn't have to:

```bash
~/.local/bin/bushel claude-setup
```

This auto-edits the user's Claude Desktop and Claude Code MCP configs so bushel's tools become available. After it succeeds, tell the user:

> Bushel is installed and registered. Restart me (Claude) to pick up the new tools, then say "Start using bushel."

If the user is in Claude Desktop or some other client without shell access, instead tell them to run `bushel claude-setup` themselves in a terminal.

## Verify the install

```bash
~/.local/bin/bushel --version           # should print 0.4.x-bushel.N
~/.local/bin/bushel ls                  # lists VMs (empty list is fine)
launchctl list | grep io.github.orzelig.bushel.daemon   # daemon registered
```

If `bushel ls` returns connection errors, the daemon failed to start — check `tail /tmp/bushel_daemon.error.log` and report it.

## Uninstall

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/uninstall.sh)
```

Preserves user data (`~/.lume/` and `~/.config/lume/`) by default. The user must pass `--purge` to delete VM data.

## Don't do these

- Don't `sudo` anything; the installer refuses to run as root.
- Don't enter the user's password into any form. The default VM credentials baked into bushel images are `lume`/`lume` — that's the VM's user account, not the host user.
- Don't run `bushel update` immediately after install — the install script already pulls the latest release; running update right after just re-fetches the same version.

## Reference

- Repo: https://github.com/orzelig/bushel
- README: https://github.com/orzelig/bushel/blob/main/README.md
- Latest release: https://github.com/orzelig/bushel/releases/latest
- Issue tracker: https://github.com/orzelig/bushel/issues
