#!/bin/bash

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
    echo "Error: $var is not set"
    exit 1
  fi
done

# Move to the project root directory
pushd ../../

# Build the release version
swift build -c release --product lume

# Sign the binary with hardened runtime entitlements
codesign --force --options runtime \
         --entitlement ./resources/lume.entitlements \
         --sign "$CERT_APPLICATION_NAME" \
         .build/release/lume

# Create a temporary directory for packaging
TEMP_ROOT=$(mktemp -d)
mkdir -p "$TEMP_ROOT/usr/local/bin"
cp -f .build/release/lume "$TEMP_ROOT/usr/local/bin/"

# Build the installer package
pkgbuild --root "$TEMP_ROOT" \
         --identifier "com.trycua.lume" \
         --version "1.0" \
         --install-location "/" \
         --sign "$CERT_INSTALLER_NAME" \
         ./.release/lume.pkg

# Submit for notarization using stored credentials
xcrun notarytool submit ./.release/lume.pkg \
    --apple-id "${APPLE_ID}" \
    --team-id "${TEAM_ID}" \
    --password "${APP_SPECIFIC_PASSWORD}" \
    --wait

# Staple the notarization ticket
xcrun stapler staple ./.release/lume.pkg

# Create temporary directory for package extraction
EXTRACT_ROOT=$(mktemp -d)
PKG_PATH="$(pwd)/.release/lume.pkg"

# Extract the pkg using xar
cd "$EXTRACT_ROOT"
xar -xf "$PKG_PATH"

# Verify Payload exists before proceeding
if [ ! -f "Payload" ]; then
    echo "Error: Payload file not found after xar extraction"
    exit 1
fi

# Create a directory for the extracted contents
mkdir -p extracted
cd extracted

# Extract the Payload
cat ../Payload | gunzip -dc | cpio -i

# Verify the binary exists
if [ ! -f "usr/local/bin/lume" ]; then
    echo "Error: lume binary not found in expected location"
    exit 1
fi

# Copy extracted lume to ./.release/lume
cp -f usr/local/bin/lume "$(dirname "$PKG_PATH")/lume"

# Create symbolic link in /usr/local/bin
cd "$(dirname "$PKG_PATH")"
sudo ln -sf "$(pwd)/lume" /usr/local/bin/lume

# Create zip archive of the package
tar -czvf lume.tar.gz lume
tar -czvf lume.pkg.tar.gz lume.pkg

# Create sha256 checksum for the lume tarball
shasum -a 256 lume.tar.gz

popd

# Clean up
rm -rf "$TEMP_ROOT"
rm -rf "$EXTRACT_ROOT"