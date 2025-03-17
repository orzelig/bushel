#!/bin/bash
set -e

# Lume Installer
# This script installs Lume to your system

# Define colors for output
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
BLUE=$(tput setaf 4)

# Default installation directory
DEFAULT_INSTALL_DIR="/usr/local/bin"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

# GitHub info
GITHUB_REPO="trycua/cua"
LATEST_RELEASE_URL="https://api.github.com/repos/$GITHUB_REPO/releases/latest"

echo "${BOLD}${BLUE}Lume Installer${NORMAL}"
echo "This script will install Lume to your system."

# Check if we're running with appropriate permissions
check_permissions() {
  if [ "$INSTALL_DIR" = "$DEFAULT_INSTALL_DIR" ] && [ "$(id -u)" != "0" ]; then
    echo "${RED}Error: Installing to $INSTALL_DIR requires root privileges.${NORMAL}"
    echo "Please run with sudo or specify a different directory with INSTALL_DIR environment variable."
    echo "Example: INSTALL_DIR=\$HOME/.local/bin $0"
    exit 1
  fi
}

# Detect OS and architecture
detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  
  if [ "$OS" != "darwin" ]; then
    echo "${RED}Error: Currently only macOS is supported.${NORMAL}"
    exit 1
  fi
  
  if [ "$ARCH" != "arm64" ]; then
    echo "${RED}Error: Lume only supports macOS on Apple Silicon (ARM64).${NORMAL}"
    exit 1
  fi
  
  PLATFORM="darwin-arm64"
  echo "Detected platform: ${BOLD}$PLATFORM${NORMAL}"
}

# Create temporary directory
create_temp_dir() {
  TEMP_DIR=$(mktemp -d)
  echo "Using temporary directory: $TEMP_DIR"
  
  # Make sure we clean up on exit
  trap 'rm -rf "$TEMP_DIR"' EXIT
}

# Download the latest release
download_release() {
  echo "Fetching latest release information..."
  
  # Try to get the latest version from GitHub API
  if command -v curl &> /dev/null; then
    RELEASE_INFO=$(curl -s "$LATEST_RELEASE_URL")
    VERSION=$(echo "$RELEASE_INFO" | grep -o '"tag_name": "v[^"]*"' | cut -d'"' -f4 | sed 's/^v//')
    
    if [ -z "$VERSION" ]; then
      echo "${RED}Failed to get latest version.${NORMAL} Using direct download link."
      # Try simpler URL with the non-versioned symlink
      DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/latest/download/lume.tar.gz"
    else
      echo "Latest version: ${BOLD}$VERSION${NORMAL}"
      DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/lume.tar.gz"
    fi
  else
    echo "${RED}curl not found.${NORMAL} Using direct download link."
    DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/latest/download/lume.tar.gz"
  fi
  
  echo "Downloading from: $DOWNLOAD_URL"
  
  # Download the tarball
  if command -v curl &> /dev/null; then
    curl -L --progress-bar "$DOWNLOAD_URL" -o "$TEMP_DIR/lume.tar.gz"
    
    # Verify the download was successful
    if [ ! -s "$TEMP_DIR/lume.tar.gz" ]; then
      echo "${RED}Error: Failed to download Lume.${NORMAL}"
      echo "The download URL may be incorrect or the file may not exist."
      exit 1
    fi
    
    # Verify the file is a valid archive
    if ! tar -tzf "$TEMP_DIR/lume.tar.gz" > /dev/null 2>&1; then
      echo "${RED}Error: The downloaded file is not a valid tar.gz archive.${NORMAL}"
      echo "Let's try the alternative URL..."
      
      # Try alternative URL
      ALT_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/latest/download/lume-$PLATFORM.tar.gz"
      echo "Downloading from alternative URL: $ALT_DOWNLOAD_URL"
      curl -L --progress-bar "$ALT_DOWNLOAD_URL" -o "$TEMP_DIR/lume.tar.gz"
      
      # Check again
      if ! tar -tzf "$TEMP_DIR/lume.tar.gz" > /dev/null 2>&1; then
        echo "${RED}Error: Could not download a valid Lume archive.${NORMAL}"
        echo "Please try installing Lume manually from: https://github.com/$GITHUB_REPO/releases/latest"
        exit 1
      fi
    fi
  else
    echo "${RED}Error: curl is required but not installed.${NORMAL}"
    exit 1
  fi
}

# Extract and install
install_binary() {
  echo "Extracting archive..."
  tar -xzf "$TEMP_DIR/lume.tar.gz" -C "$TEMP_DIR"
  
  echo "Installing to $INSTALL_DIR..."
  
  # Create install directory if it doesn't exist
  mkdir -p "$INSTALL_DIR"
  
  # Move the binary to the installation directory
  mv "$TEMP_DIR/lume" "$INSTALL_DIR/"
  
  # Make the binary executable
  chmod +x "$INSTALL_DIR/lume"
  
  echo "${GREEN}Installation complete!${NORMAL}"
  echo "Lume has been installed to ${BOLD}$INSTALL_DIR/lume${NORMAL}"
  
  # Check if the installation directory is in PATH
  if [ -n "${PATH##*$INSTALL_DIR*}" ]; then
    echo "${RED}Warning: $INSTALL_DIR is not in your PATH.${NORMAL}"
    echo "You may need to add it to your shell profile:"
    echo "  For bash: echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.bash_profile"
    echo "  For zsh:  echo 'export PATH=\"\$PATH:$INSTALL_DIR\"' >> ~/.zshrc"
    echo "  For fish: echo 'fish_add_path $INSTALL_DIR' >> ~/.config/fish/config.fish"
  fi
}

# Main installation flow
main() {
  check_permissions
  detect_platform
  create_temp_dir
  download_release
  install_binary
  
  echo ""
  echo "${GREEN}${BOLD}Lume has been successfully installed!${NORMAL}"
  echo "Run ${BOLD}lume${NORMAL} to get started."
}

# Run the installation
main 