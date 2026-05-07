#!/bin/bash
# Bushel Installer - installs the bushel CLI and macOS daemon LaunchAgent.
#
# curl-bash:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/orzelig/bushel/main/scripts/install.sh)"
#
# Apple Silicon / macOS only. Inherits lume's data layout (~/.lume,
# ~/.config/lume) for migration; this script does not touch those dirs.
# Auto-update is OFF by default for v1 (re-run install.sh to upgrade).
# No telemetry, no phone-home.

set -eu

# Refuse ancient bash.
if [ -n "${BASH_VERSION:-}" ] && [ "${BASH_VERSION%%.*}" -lt 3 ]; then
  echo "Error: bash >= 3 is required (found $BASH_VERSION)." >&2; exit 1
fi

# ---- styling (guarded so piping to a file doesn't dump escape codes) -------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold); NORMAL=$(tput sgr0)
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); BLUE=$(tput setaf 4)
else
  BOLD=""; NORMAL=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi
info()  { echo "${BLUE}==>${NORMAL} $*"; }
ok()    { echo "${GREEN}==>${NORMAL} $*"; }
warn()  { echo "${YELLOW}warning:${NORMAL} $*" >&2; }
fail()  { echo "${RED}error:${NORMAL} $*" >&2; exit 1; }

# ---- configuration ---------------------------------------------------------
GITHUB_REPO="orzelig/bushel"
TARBALL_NAME="bushel-darwin-arm64.tar.gz"
BINARY_NAME="bushel"
DEFAULT_INSTALL_DIR="$HOME/.local/bin"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
RESOURCE_DIR="$HOME/.local/share/bushel"
SERVICE_LABEL="io.github.orzelig.bushel.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
DAEMON_LOG="/tmp/bushel_daemon.log"
DAEMON_ERR_LOG="/tmp/bushel_daemon.error.log"
BUSHEL_PORT="${BUSHEL_PORT:-7777}"
ENABLE_AUTO_UPDATE_CHECK=true   # daily check + macOS notification (no auto-apply)
INSTALL_BACKGROUND_SERVICE=true
VERSION_TAG=""  # empty = latest
UPDATER_LABEL="io.github.orzelig.bushel.updater"
UPDATER_PLIST_PATH="$HOME/Library/LaunchAgents/${UPDATER_LABEL}.plist"
UPDATER_LOG="/tmp/bushel_updater.log"
UPDATER_ERR_LOG="/tmp/bushel_updater.error.log"

usage() {
  cat <<USAGE
${BOLD}${BLUE}Bushel Installer${NORMAL}
Usage: $0 [OPTIONS]

  --install-dir DIR         Binary install dir (default: ${DEFAULT_INSTALL_DIR})
  --port PORT               Daemon port (default: 7777, wire-compatible with lume)
  --version TAG             Pin to a release tag (e.g. v0.4.0-bushel.0)
  --no-auto-update-check    Skip the daily 'bushel update --check-only --notify'
                            LaunchAgent (still installs the 'bushel update' subcommand).
  --no-background-service   Skip the daemon LaunchAgent setup entirely
  --help                    This message

Env vars: INSTALL_DIR, BUSHEL_PORT (same as flags above).
USAGE
}

# ---- argument parsing ------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dir) INSTALL_DIR="${2:-}"; shift ;;
    --install-dir=*) INSTALL_DIR="${1#*=}" ;;
    --port) BUSHEL_PORT="${2:-}"; shift ;;
    --port=*) BUSHEL_PORT="${1#*=}" ;;
    --version) VERSION_TAG="${2:-}"; shift ;;
    --version=*) VERSION_TAG="${1#*=}" ;;
    --no-auto-update-check) ENABLE_AUTO_UPDATE_CHECK=false ;;
    --no-background-service) INSTALL_BACKGROUND_SERVICE=false ;;
    --help|-h) usage; exit 0 ;;
    *) echo "${RED}Unknown option: $1${NORMAL}"; usage; exit 1 ;;
  esac
  shift
done

# ============================ Phase 1: preflight ===========================
preflight() {
  if [ "$(id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
    fail "Do not run as root or via sudo.
For privileged install paths, create the dir yourself first:
  sudo mkdir -p /desired/dir && sudo chown $(whoami) /desired/dir
then: ./install.sh --install-dir=/desired/dir"
  fi

  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
  [ "$os" = "darwin" ] || fail "Bushel only supports macOS (got: $os)."
  [ "$arch" = "arm64" ] || fail "Bushel requires Apple Silicon (arm64); got: $arch."
  info "Platform: ${BOLD}darwin-arm64${NORMAL}"

  for tool in curl tar launchctl plutil grep sed; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool"
  done

  # Conflict checks: informative, non-fatal. Bushel is wire-compatible with
  # lume on port 7777 so coexistence is fine if only one daemon is bound.
  if command -v lume >/dev/null 2>&1; then
    warn "'lume' is already installed at $(command -v lume).
    Bushel is wire-compatible (default port 7777). If both daemons try to
    bind the same port, one will fail. Continuing."
  fi
  if launchctl list 2>/dev/null | grep -q "$SERVICE_LABEL"; then
    info "Existing ${SERVICE_LABEL} LaunchAgent detected; will be reloaded."
  fi
  if [ -f "$INSTALL_DIR/$BINARY_NAME" ]; then
    info "Previous bushel install at $INSTALL_DIR/$BINARY_NAME; unloading daemon."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
  fi
}

# ============================ Phase 2: download ============================
resolve_release_tag() {
  if [ -n "$VERSION_TAG" ]; then echo "$VERSION_TAG"; return 0; fi

  # Prefer /releases/latest; fall back to scanning /releases for first v* tag.
  local response tag
  response=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || echo "")
  tag=$(printf '%s\n' "$response" | grep -oE '"tag_name":[[:space:]]*"v[^"]*"' \
        | head -n1 | sed -E 's/.*"tag_name":[[:space:]]*"([^"]*)".*/\1/')
  if [ -n "$tag" ]; then echo "$tag"; return 0; fi

  response=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30" 2>/dev/null || echo "")
  tag=$(printf '%s\n' "$response" | grep -oE '"tag_name":[[:space:]]*"v[^"]*"' \
        | head -n1 | sed -E 's/.*"tag_name":[[:space:]]*"([^"]*)".*/\1/')
  [ -n "$tag" ] || fail "Could not determine latest bushel release tag from GitHub."
  echo "$tag"
}

download_release() {
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TEMP_DIR"' EXIT

  info "Resolving release tag..."
  RELEASE_TAG=$(resolve_release_tag)
  ok "Using release: ${BOLD}${RELEASE_TAG}${NORMAL}"

  local url path
  url="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}/${TARBALL_NAME}"
  path="$TEMP_DIR/$TARBALL_NAME"

  info "Downloading ${TARBALL_NAME}..."
  if ! curl -fL --progress-bar "$url" -o "$path"; then
    fail "Download failed: $url
See https://github.com/${GITHUB_REPO}/releases/tag/${RELEASE_TAG} for available assets."
  fi
  [ -s "$path" ] || fail "Downloaded tarball is empty."
  tar -tzf "$path" >/dev/null 2>&1 || fail "Not a valid tar.gz: $path"
  TARBALL_PATH="$path"
}

# ============================ Phase 3: install =============================
install_artifacts() {
  info "Extracting archive..."
  tar -xzf "$TARBALL_PATH" -C "$TEMP_DIR"

  # Locate the binary (top-level or one level deep). Adjust here if release
  # workflow changes layout.
  local found
  found=$(find "$TEMP_DIR" -type f -name "$BINARY_NAME" -perm -u+x 2>/dev/null | head -n1)
  [ -n "$found" ] || found=$(find "$TEMP_DIR" -type f -name "$BINARY_NAME" 2>/dev/null | head -n1)
  [ -n "$found" ] || fail "No '$BINARY_NAME' binary found inside ${TARBALL_NAME}."

  mkdir -p "$INSTALL_DIR"
  install -m 0755 "$found" "$INSTALL_DIR/$BINARY_NAME"
  ok "Installed binary: ${BOLD}$INSTALL_DIR/$BINARY_NAME${NORMAL}"

  # SPM resource bundle (bushel_bushel.bundle). Must live adjacent to the
  # binary — Bundle.module resolves resources relative to the executable's
  # location. Without this, unattended-install YAML presets fail to load.
  local bundle
  bundle=$(find "$TEMP_DIR" -maxdepth 3 -type d -name "${BINARY_NAME}_${BINARY_NAME}.bundle" 2>/dev/null | head -n1)
  if [ -n "$bundle" ]; then
    rm -rf "$INSTALL_DIR/${BINARY_NAME}_${BINARY_NAME}.bundle"
    cp -R "$bundle" "$INSTALL_DIR/"
    ok "Installed resource bundle: ${BOLD}$INSTALL_DIR/${BINARY_NAME}_${BINARY_NAME}.bundle${NORMAL}"
  else
    warn "Resource bundle not found in tarball — unattended-install presets unavailable."
  fi

  # Optional separate resources dir shipped in the tarball (rare; reserved
  # for future use, e.g. doc/example payloads not part of the SPM bundle).
  local rsrc=""
  for c in "$TEMP_DIR/resources" "$TEMP_DIR/share" "$TEMP_DIR/$BINARY_NAME/resources"; do
    [ -d "$c" ] && { rsrc="$c"; break; }
  done
  if [ -n "$rsrc" ]; then
    mkdir -p "$RESOURCE_DIR"
    cp -R "$rsrc/." "$RESOURCE_DIR/"
    ok "Installed resources to ${BOLD}$RESOURCE_DIR${NORMAL}"
  fi
}

path_advice() {
  case ":$PATH:" in *":$INSTALL_DIR:"*) return 0 ;; esac
  local sh; sh=$(basename "${SHELL:-bash}")
  echo ""
  echo "${YELLOW}${BOLD}PATH not configured:${NORMAL} ${INSTALL_DIR} is not on \$PATH."
  case "$sh" in
    zsh)  echo "  echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.zshrc && source ~/.zshrc" ;;
    bash) echo "  echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.bash_profile && source ~/.bash_profile" ;;
    fish) echo "  echo 'fish_add_path $INSTALL_DIR' >> ~/.config/fish/config.fish" ;;
    *)    echo "  Add $INSTALL_DIR to PATH in your shell profile." ;;
  esac
  echo "Until then, invoke ${BOLD}$INSTALL_DIR/$BINARY_NAME${NORMAL} directly."
}

# ============================ Phase 4: daemon ==============================
install_launch_agent() {
  if [ "$INSTALL_BACKGROUND_SERVICE" != true ]; then
    info "Skipping LaunchAgent setup (--no-background-service)."; return 0
  fi

  mkdir -p "$HOME/Library/LaunchAgents"
  # Idempotent unload before write — re-running install.sh shouldn't leave
  # the previous daemon attached to a stale binary.
  [ -f "$PLIST_PATH" ] && launchctl unload "$PLIST_PATH" 2>/dev/null || true

  # Migration from bushel <= 0.4.0-bushel.6, which used the prefix
  # 'dev.orzelig.bushel.*'. Unload and remove the old plist so an upgrade
  # doesn't leave two daemons fighting over port 7777.
  local legacy_plist="$HOME/Library/LaunchAgents/dev.orzelig.bushel.daemon.plist"
  if [ -f "$legacy_plist" ]; then
    launchctl unload "$legacy_plist" 2>/dev/null || true
    rm -f "$legacy_plist"
    info "Removed legacy LaunchAgent (dev.orzelig.bushel.daemon)."
  fi

  local tmpl
  tmpl=$(cat <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.orzelig.bushel.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>__BUSHEL_BIN__</string>
        <string>serve</string>
        <string>--port</string>
        <string>__BUSHEL_PORT__</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/bushel_daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/bushel_daemon.error.log</string>
    <key>WorkingDirectory</key>
    <string>__HOME__</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:__HOME__/.local/bin</string>
        <key>HOME</key>
        <string>__HOME__</string>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST_EOF
)
  # Substitute placeholders. '|' delimiter avoids collision with path '/'.
  printf '%s\n' "$tmpl" \
    | sed "s|__BUSHEL_BIN__|$INSTALL_DIR/$BINARY_NAME|g" \
    | sed "s|__BUSHEL_PORT__|$BUSHEL_PORT|g" \
    | sed "s|__HOME__|$HOME|g" \
    > "$PLIST_PATH"
  chmod 644 "$PLIST_PATH"

  plutil -lint "$PLIST_PATH" >/dev/null || fail "Generated plist is invalid: $PLIST_PATH"

  : > "$DAEMON_LOG" 2>/dev/null || true
  : > "$DAEMON_ERR_LOG" 2>/dev/null || true
  chmod 644 "$DAEMON_LOG" "$DAEMON_ERR_LOG" 2>/dev/null || true

  info "Loading LaunchAgent..."
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  if ! launchctl load "$PLIST_PATH"; then
    warn "launchctl load failed; binary installed but daemon not running.
       Retry with: launchctl load $PLIST_PATH"
    return 0
  fi
  ok "LaunchAgent ${BOLD}${SERVICE_LABEL}${NORMAL} loaded."
}

# ============================ Phase 5: post-install ========================
install_update_check_agent() {
  if [ "$ENABLE_AUTO_UPDATE_CHECK" != true ]; then
    info "Daily update-check LaunchAgent: skipped (--no-auto-update-check)."
    return 0
  fi

  # Idempotent: unload any prior version before writing.
  [ -f "$UPDATER_PLIST_PATH" ] && launchctl unload "$UPDATER_PLIST_PATH" 2>/dev/null || true

  local tmpl
  tmpl=$(cat <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.orzelig.bushel.updater</string>
    <key>ProgramArguments</key>
    <array>
        <string>__BUSHEL_BIN__</string>
        <string>update</string>
        <string>--check-only</string>
        <string>--notify</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>10</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/bushel_updater.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/bushel_updater.error.log</string>
</dict>
</plist>
PLIST_EOF
)
  printf '%s\n' "$tmpl" \
    | sed "s|__BUSHEL_BIN__|$INSTALL_DIR/$BINARY_NAME|g" \
    > "$UPDATER_PLIST_PATH"
  chmod 644 "$UPDATER_PLIST_PATH"
  plutil -lint "$UPDATER_PLIST_PATH" >/dev/null || fail "Generated updater plist is invalid: $UPDATER_PLIST_PATH"

  if launchctl load "$UPDATER_PLIST_PATH" 2>/dev/null; then
    ok "Daily update check installed: ${BOLD}$UPDATER_LABEL${NORMAL} (10:00 daily)."
    info "  The check runs '$BINARY_NAME update --check-only --notify'. It posts a"
    info "  macOS notification when an update is available; it never auto-applies."
  else
    warn "Failed to load update-check LaunchAgent. Run 'launchctl load $UPDATER_PLIST_PATH' manually."
  fi
}

print_summary() {
  echo ""
  ok "${BOLD}Bushel installed.${NORMAL}"
  echo "  Binary:        $INSTALL_DIR/$BINARY_NAME"
  echo "  Resources:     $RESOURCE_DIR"
  echo "  LaunchAgent:   $PLIST_PATH"

  if [ "$INSTALL_BACKGROUND_SERVICE" = true ]; then
    echo ""
    echo "${BOLD}Daemon status:${NORMAL}"
    if launchctl list 2>/dev/null | grep -E "(^|[[:space:]])${SERVICE_LABEL}([[:space:]]|$)" >/dev/null; then
      launchctl list | grep "$SERVICE_LABEL" | sed 's/^/  /'
      echo "  (PID '-' means the process exited; check logs.)"
    else
      warn "${SERVICE_LABEL} not in launchctl list."
    fi
    echo ""
    echo "Logs:  tail -f $DAEMON_LOG"
    echo "       tail -f $DAEMON_ERR_LOG"
  fi

  path_advice

  local bushel_cmd="$INSTALL_DIR/$BINARY_NAME"
  if echo ":$PATH:" | grep -q ":$INSTALL_DIR:"; then
    bushel_cmd="$BINARY_NAME"
  fi

  echo ""
  echo "${BOLD}Use with Claude:${NORMAL}"
  echo "  If you already have Claude Code open, just tell it:"
  echo "      ${BOLD}\"Run bushel claude-setup, then I'll restart you.\"${NORMAL}"
  echo "  Otherwise, run it yourself: ${BOLD}${bushel_cmd} claude-setup${NORMAL}"
  echo ""
  echo "  Then restart Claude (Desktop and/or Code) and ask it:"
  echo "      ${BOLD}\"Start using bushel.\"${NORMAL}"
  echo ""
  echo "Or just run ${BOLD}${bushel_cmd} --help${NORMAL}."
}

main() {
  echo "${BOLD}${BLUE}Bushel Installer${NORMAL} - orzelig/bushel"
  preflight
  download_release
  install_artifacts
  install_launch_agent
  install_update_check_agent
  print_summary
}

main "$@"
