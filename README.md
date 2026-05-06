# Bushel

CLI and framework for macOS and Linux VMs using Apple Virtualization Framework.

## What is bushel?

Bushel is a maintained fork of [lume](https://github.com/trycua/cua/tree/main/libs/lume), extracted from the [trycua/cua](https://github.com/trycua/cua) monorepo via `git filter-repo --subdirectory-filter libs/lume` (history preserved). It carries fixes ahead of upstream:

- [trycua/cua#1395](https://github.com/trycua/cua/pull/1395) — `lume pull macos-*` now correctly assembles 21 GB OCI tar-part disk images
- [trycua/cua#1441](https://github.com/trycua/cua/pull/1441) — `lume create --unattended` Tahoe preset works on macOS 26's renamed Setup Assistant buttons

See [UPSTREAM-STATUS.md](UPSTREAM-STATUS.md) for the full relationship to upstream — provenance, vendored PRs, and open PRs under evaluation.

## Why is the binary still called `lume`?

The CLI binary is still `lume`. This is deliberate: every `lume pull`, `lume create`, etc. invocation continues to work unchanged, and existing automation (LaunchAgents, scripts, the `lume serve` HTTP API on `127.0.0.1:7777`) keeps working without modification. Whether to rename the CLI to `bushel` is an open question; for now, treat the project name and the binary name as separate.

## Documentation

**[Upstream lume documentation](https://cua.ai/docs/lume)** — installation, guides, and API reference. These docs describe upstream lume, which bushel is based on; bushel is CLI-compatible, so they apply to bushel too except where the vendored fixes above change behavior.

## Installation

Bushel does not yet have its own installer. To build from source:

```bash
swift build -c release
```

The resulting binary lives at `.build/arm64-apple-macosx/release/lume`. Apple Silicon only — `Virtualization.framework` requires an M-series Mac.

## Relationship to upstream

Bushel will keep tracking upstream lume. The intent is to vendor open PRs that fix real bugs (and occasionally low-risk features) ahead of upstream's review cadence, then reconcile when those PRs land. If upstream catches up on the issues bushel is working around, the fork will likely fold back.

For the current vendored set, open PRs under evaluation, and known unaddressed issues, see [UPSTREAM-STATUS.md](UPSTREAM-STATUS.md). For bushel-specific bugs, file an issue on this repo; for bugs that exist upstream too, please cross-link the upstream issue.
