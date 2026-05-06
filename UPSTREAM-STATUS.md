# Upstream status

`bushel` is a maintained fork of [trycua/cua's `libs/lume`](https://github.com/trycua/cua/tree/main/libs/lume), extracted into a standalone repository so it can ship fixes quickly while the upstream project's review cadence catches up.

This file tracks the relationship to upstream: what we've vendored, what we're considering, and what upstream issues bushel resolves out of the box.

## Provenance

- **Forked from:** `trycua/cua` @ commit `534304f5` (latest main as of 2026-05-06)
- **Extracted via:** `git filter-repo --subdirectory-filter libs/lume`, preserving lume's commit history
- **Last upstream lume version merged:** v0.3.9
- **License:** MIT (preserved from upstream)

## Vendored upstream PRs (applied to bushel `main`)

| Upstream PR | Title | Bushel commit | Status |
|---|---|---|---|
| [trycua/cua#1395](https://github.com/trycua/cua/pull/1395) | fix(lume): pull 21GB OCI tar-part images without skipping disk layers | `442c116` | Applied |
| [trycua/cua#1441](https://github.com/trycua/cua/pull/1441) | fix(lume): update tahoe unattended preset for macOS 26 Setup Assistant changes | `968fb0f` | Applied |

Both PRs remain open upstream. If they merge upstream, the bushel commits will be reconciled (likely a no-op rebase).

## Upstream issues fixed in bushel

These upstream issues are resolved on bushel `main`. If you hit one of them on stock lume, bushel is the workaround.

| Upstream issue | Title | Resolved by |
|---|---|---|
| [trycua/cua#1102](https://github.com/trycua/cua/issues/1102) | lume pull skips multi-part tar layers, fails to assemble disk image | Applied #1395 |
| [trycua/cua#1440](https://github.com/trycua/cua/issues/1440) | unattended tahoe preset fails on macOS 26.4.1: 'Set Up Later' button renamed to 'Skip' | Applied #1441 |

## Open upstream PRs under evaluation

These look worth vendoring; not yet applied. Evaluation order is rough; please open an issue if one is blocking you and we'll prioritize it.

| Upstream PR | Title | Notes |
|---|---|---|
| [trycua/cua#1254](https://github.com/trycua/cua/pull/1254) | fix(lume): handle guest-initiated VM shutdown via VZVirtualMachineDelegate | Would resolve upstream issue #1184 |
| [trycua/cua#1436](https://github.com/trycua/cua/pull/1436) | Fix force unwrap crash on optional macAddress in VM context creation | Small bugfix, low risk |
| [trycua/cua#941](https://github.com/trycua/cua/pull/941) | feat(lume): add `compact` and `expand` | Feature add; needs review for scope fit |
| [trycua/cua#1082](https://github.com/trycua/cua/pull/1082) | feat(lume): add option to specify custom config file path | Feature add; small surface |

## Notable open upstream issues (not yet addressed)

Tracking these for visibility — they're known limitations that bushel hasn't tackled yet.

- [trycua/cua#15](https://github.com/trycua/cua/issues/15) — VM snapshot management
- [trycua/cua#58](https://github.com/trycua/cua/issues/58) — Nested virtualization support
- [trycua/cua#75](https://github.com/trycua/cua/issues/75) — NoVNC support
- [trycua/cua#925](https://github.com/trycua/cua/issues/925) — Allow disk image resize (shrink)
- [trycua/cua#1133](https://github.com/trycua/cua/issues/1133) — Bridge network failed in homebrew release
- [trycua/cua#1184](https://github.com/trycua/cua/issues/1184) — Guest-initiated shutdown leaves VM process running

## Reporting bushel-specific issues

For bushel-specific bugs or feature requests, file an issue on this repo. For bugs that exist in upstream lume too, please cross-link the upstream issue so we can keep tracking aligned.
