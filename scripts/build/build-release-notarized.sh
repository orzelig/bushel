#!/bin/bash

# Set default log level if not provided
LOG_LEVEL=${LOG_LEVEL:-"normal"}

# Function to log based on level
log() {
  local level=$1
  local message=$2
  
  case "$LOG_LEVEL" in
    "minimal")
      # Only show essential or error messages
      if [ "$level" = "essential" ] || [ "$level" = "error" ]; then
        echo "$message"
      fi
      ;;
    "none")
      # Show nothing except errors
      if [ "$level" = "error" ]; then
        echo "$message" >&2
      fi
      ;;
    *)
      # Normal logging - show everything
      echo "$message"
      ;;
  esac
}

# Check required environment variables
required_vars=(
  "CERT_APPLICATION_NAME"
  "CERT_INSTALLER_NAME"
  "APPLE_ID"
  "TEAM_ID"
  "APP_SPECIFIC_PASSWORD"
)

for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    log "error" "Error: $var is not set"
    exit 1
  fi
done

# Get VERSION from environment or use default
VERSION=${VERSION:-"0.1.0"}

# Move to the project root directory
pushd ../../ > /dev/null

# Build the release version
log "essential" "Building release version..."
swift build -c release --product lume > /dev/null

# Sign the binary with hardened runtime entitlements
log "essential" "Signing binary with entitlements..."
codesign --force --options runtime \
         --entitlement ./resources/lume.entitlements \
         --sign "$CERT_APPLICATION_NAME" \
         .build/release/lume 2> /dev/null

# Create a temporary directory for packaging
TEMP_ROOT=$(mktemp -d)
mkdir -p "$TEMP_ROOT/usr/local/bin"
cp -f .build/release/lume "$TEMP_ROOT/usr/local/bin/"

# Build the installer package
log "essential" "Building installer package..."
pkgbuild --root "$TEMP_ROOT" \
         --identifier "com.trycua.lume" \
         --version "1.0" \
         --install-location "/" \
         --sign "$CERT_INSTALLER_NAME" \
         ./.release/lume.pkg 2> /dev/null

# Submit for notarization using stored credentials
log "essential" "Submitting for notarization..."
if [ "$LOG_LEVEL" = "minimal" ] || [ "$LOG_LEVEL" = "none" ]; then
  # Minimal output - capture ID but hide details
  NOTARY_OUTPUT=$(xcrun notarytool submit ./.release/lume.pkg \
      --apple-id "${APPLE_ID}" \
      --team-id "${TEAM_ID}" \
      --password "${APP_SPECIFIC_PASSWORD}" \
      --wait 2>&1)
  
  # Just show success or failure
  if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
    log "essential" "Notarization successful!"
  else
    log "error" "Notarization failed. Please check logs."
  fi
else
  # Normal verbose output
  xcrun notarytool submit ./.release/lume.pkg \
      --apple-id "${APPLE_ID}" \
      --team-id "${TEAM_ID}" \
      --password "${APP_SPECIFIC_PASSWORD}" \
      --wait
fi

# Staple the notarization ticket
log "essential" "Stapling notarization ticket..."
xcrun stapler staple ./.release/lume.pkg > /dev/null 2>&1

# Create temporary directory for package extraction
EXTRACT_ROOT=$(mktemp -d)
PKG_PATH="$(pwd)/.release/lume.pkg"

# Extract the pkg using xar
cd "$EXTRACT_ROOT"
xar -xf "$PKG_PATH" > /dev/null 2>&1

# Verify Payload exists before proceeding
if [ ! -f "Payload" ]; then
    log "error" "Error: Payload file not found after xar extraction"
    exit 1
fi

# Create a directory for the extracted contents
mkdir -p extracted
cd extracted

# Extract the Payload
cat ../Payload | gunzip -dc | cpio -i > /dev/null 2>&1

# Verify the binary exists
if [ ! -f "usr/local/bin/lume" ]; then
    log "error" "Error: lume binary not found in expected location"
    exit 1
fi

# Copy extracted lume to ./.release/lume
cp -f usr/local/bin/lume "$(dirname "$PKG_PATH")/lume"

# Create symbolic link in /usr/local/bin if not in minimal mode
if [ "$LOG_LEVEL" != "minimal" ] && [ "$LOG_LEVEL" != "none" ]; then
  log "normal" "Creating symbolic link..."
  cd "$(dirname "$PKG_PATH")"
  sudo ln -sf "$(pwd)/lume" /usr/local/bin/lume
fi

# Get architecture and create OS identifier
ARCH=$(uname -m)
OS_IDENTIFIER="darwin-${ARCH}"

# Create versioned archives of the package with OS identifier in the name
log "essential" "Creating archives with OS identifier..."
cd "$(dirname "$PKG_PATH")"

# Create version-specific archives
log "essential" "Creating version-specific archives (${VERSION})..."
tar -czf "lume-${VERSION}-${OS_IDENTIFIER}.tar.gz" lume > /dev/null 2>&1
tar -czf "lume-${VERSION}-${OS_IDENTIFIER}.pkg.tar.gz" lume.pkg > /dev/null 2>&1

# Delete temporary package files that we don't need to upload
log "normal" "Cleaning up temporary files..."
rm -f lume.pkg
rm -f lume

# Create sha256 checksum file
log "essential" "Generating checksums..."
shasum -a 256 lume-*.tar.gz > checksums.txt
log "essential" "Package created successfully with checksums generated."

# Show what we're publishing
ls -la *.tar.gz *.pkg.tar.gz

popd > /dev/null

# Clean up
rm -rf "$TEMP_ROOT"
rm -rf "$EXTRACT_ROOT"