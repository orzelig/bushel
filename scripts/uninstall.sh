#!/bin/bash
#
# Bushel Uninstaller
# Removes the bushel binary, LaunchAgent, and log files.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/uninstall.sh)"
#
# By default this preserves user data:
#   - ~/.lume/             (VMs and cache; shared with lume by design)
#   - ~/.config/lume/      (configuration; shared with lume by design)
#   - ~/.local/share/bushel/ (bushel-only resources)
# Pass --purge to remove all of the above.
#

set -eu

if [ -n "${BASH_VERSION:-}" ]; then
  BASH_MAJOR="${BASH_VERSION%%.*}"
  if [ "$BASH_MAJOR" -lt 3 ]; then
    echo "Error: bash >= 3 is required (found $BASH_VERSION)." >&2
    exit 1
  fi
fi

# ----------------------------------------------------------------------------
# Output styling
# ----------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold)
  NORMAL=$(tput sgr0)
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
else
  BOLD=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi

info()  { echo "${BLUE}==>${NORMAL} $*"; }
ok()    { echo "${GREEN}==>${NORMAL} $*"; }
warn()  { echo "${YELLOW}warning:${NORMAL} $*" >&2; }
fail()  { echo "${RED}error:${NORMAL} $*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Configuration (must match install.sh)
# ----------------------------------------------------------------------------
BINARY_NAME="bushel"
SERVICE_LABEL="dev.orzelig.bushel.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
DAEMON_LOG="/tmp/bushel_daemon.log"
DAEMON_ERR_LOG="/tmp/bushel_daemon.error.log"
RESOURCE_DIR="$HOME/.local/share/bushel"

PURGE=false
FORCE=false

# Tracking what we removed / preserved for the final report.
REMOVED=()
PRESERVED=()

usage() {
  cat <<USAGE
${BOLD}${BLUE}Bushel Uninstaller${NORMAL}
Usage: $0 [OPTIONS]

Options:
  --purge      Also remove user data (~/.lume, ~/.config/lume, ~/.local/share/bushel)
               WARNING: this deletes any VMs / configuration shared with lume.
  --force      Skip the confirmation prompt
  --help       Show this message
USAGE
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge) PURGE=true ;;
    --force|-f) FORCE=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "${RED}Unknown option: $1${NORMAL}"; usage; exit 1 ;;
  esac
  shift
done

# ============================================================================
# Phase 1: preflight + confirmation
# ============================================================================
echo "${BOLD}${BLUE}Bushel Uninstaller${NORMAL}"

if [ "$FORCE" != true ]; then
  echo ""
  echo "About to uninstall bushel:"
  echo "  - Stop and remove LaunchAgent ${SERVICE_LABEL}"
  echo "  - Remove the bushel binary"
  echo "  - Remove daemon log files"
  if [ "$PURGE" = true ]; then
    echo ""
    echo "${YELLOW}${BOLD}--purge${NORMAL}${YELLOW} will ALSO delete:${NORMAL}"
    echo "  - ~/.lume/             (VMs and cache; shared with lume)"
    echo "  - ~/.config/lume/      (configuration; shared with lume)"
    echo "  - $RESOURCE_DIR"
  fi
  echo ""
  printf "Continue? [y/N] "
  read -r REPLY
  case "$REPLY" in
    [Yy]*) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

# ============================================================================
# Phase 2: stop daemon (must happen before deleting the binary it points at)
# ============================================================================
info "Stopping bushel daemon..."
if [ -f "$PLIST_PATH" ]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  ok "Removed LaunchAgent: $PLIST_PATH"
  REMOVED+=("$PLIST_PATH")
else
  info "  LaunchAgent not present (skipped)."
fi

# Best-effort: if a daemon is still in launchctl's list (e.g. the plist file
# was already gone but the agent stayed loaded), try to remove it.
if launchctl list 2>/dev/null | grep -q "$SERVICE_LABEL"; then
  launchctl remove "$SERVICE_LABEL" 2>/dev/null || true
fi

# ============================================================================
# Phase 3: remove binary
# ============================================================================
info "Removing bushel binary..."

# Locate the binary: $PATH first, then the usual install dirs.
BUSHEL_BIN=""
if command -v "$BINARY_NAME" >/dev/null 2>&1; then
  BUSHEL_BIN=$(command -v "$BINARY_NAME")
else
  for loc in "$HOME/.local/bin/$BINARY_NAME" "/usr/local/bin/$BINARY_NAME" "/opt/homebrew/bin/$BINARY_NAME"; do
    if [ -f "$loc" ]; then
      BUSHEL_BIN="$loc"
      break
    fi
  done
fi

if [ -n "$BUSHEL_BIN" ] && [ -f "$BUSHEL_BIN" ]; then
  rm -f "$BUSHEL_BIN"
  ok "Removed binary: $BUSHEL_BIN"
  REMOVED+=("$BUSHEL_BIN")
  # Remove the SPM resource bundle that lives next to the binary.
  bin_dir=$(dirname "$BUSHEL_BIN")
  bundle="$bin_dir/${BINARY_NAME}_${BINARY_NAME}.bundle"
  if [ -d "$bundle" ]; then
    rm -rf "$bundle"
    ok "Removed resource bundle: $bundle"
    REMOVED+=("$bundle")
  fi
else
  info "  Binary not found (skipped)."
fi

# ============================================================================
# Phase 4: remove log files
# ============================================================================
info "Removing log files..."
for logfile in "$DAEMON_LOG" "$DAEMON_ERR_LOG"; do
  if [ -f "$logfile" ]; then
    rm -f "$logfile"
    ok "Removed: $logfile"
    REMOVED+=("$logfile")
  fi
done

# ============================================================================
# Phase 5: purge (opt-in)
# ============================================================================
if [ "$PURGE" = true ]; then
  warn "Purging user data..."

  # Try to stop running VMs before nuking ~/.lume so we don't leave
  # processes attached to deleted disk images.
  if [ -n "$BUSHEL_BIN" ] && [ -x "$BUSHEL_BIN" ]; then
    "$BUSHEL_BIN" ls 2>/dev/null \
      | awk 'NR>1 && ($2=="running" || $2=="starting") {print $1}' \
      | while read -r vm; do
          [ -n "$vm" ] && "$BUSHEL_BIN" stop "$vm" 2>/dev/null || true
        done
  fi

  for d in "$HOME/.lume" "$HOME/.config/lume" "$RESOURCE_DIR"; do
    if [ -d "$d" ]; then
      rm -rf "$d"
      ok "Removed: $d"
      REMOVED+=("$d")
    fi
  done
else
  for d in "$HOME/.lume" "$HOME/.config/lume" "$RESOURCE_DIR"; do
    if [ -d "$d" ]; then
      PRESERVED+=("$d")
    fi
  done
fi

# ============================================================================
# Phase 6: report
# ============================================================================
echo ""
ok "${BOLD}Bushel uninstalled.${NORMAL}"

if [ "${#REMOVED[@]}" -gt 0 ]; then
  echo ""
  echo "${BOLD}Removed:${NORMAL}"
  for item in "${REMOVED[@]}"; do
    echo "  - $item"
  done
fi

if [ "${#PRESERVED[@]}" -gt 0 ]; then
  echo ""
  echo "${BOLD}Preserved${NORMAL} (re-run with ${BOLD}--purge${NORMAL} to delete):"
  for item in "${PRESERVED[@]}"; do
    echo "  - $item"
  done
fi

echo ""
