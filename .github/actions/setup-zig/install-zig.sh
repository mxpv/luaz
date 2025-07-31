#!/bin/bash

# Script to download and install Zig with GitHub Actions caching support
# Usage: ./install-zig.sh <version>
#
# To enable archive caching in GitHub Actions, cache the directory: ~/.zig
# This will reuse downloaded archives across workflow runs and skip downloads.

set -euo pipefail

# Cleanup function for error handling
cleanup() {
    if [ -n "${ZIG_DIR:-}" ] && [ -d "${ZIG_DIR}" ]; then
        echo "Cleaning up partial installation: ${ZIG_DIR}"
        rm -rf "${ZIG_DIR}"
    fi
}

# Set trap to cleanup on error
trap cleanup ERR

# Check if version is provided
if [ $# -eq 0 ]; then
    echo "Error: Version parameter required"
    echo "Usage: $0 <version>"
    echo "Example: $0 0.13.0"
    exit 1
fi

VERSION="$1"
INSTALL_DIR="$(pwd)/.zig-install"
ZIG_DIR="${INSTALL_DIR}/zig-${VERSION}"

# Detect OS and architecture
case "$(uname -s)" in
    Linux*)     OS="linux";;
    Darwin*)    OS="macos";;
    CYGWIN*|MINGW*|MSYS*) OS="windows";;
    *)          echo "Unsupported OS: $(uname -s)"; exit 1;;
esac

case "$(uname -m)" in
    x86_64|amd64)   ARCH="x86_64";;
    aarch64|arm64)  ARCH="aarch64";;
    *)              echo "Unsupported architecture: $(uname -m)"; exit 1;;
esac

# Construct filename and URL
if [ "$OS" = "windows" ]; then
    FILENAME="zig-${ARCH}-${OS}-${VERSION}.zip"
    EXTRACT_CMD="unzip -q"
else
    FILENAME="zig-${ARCH}-${OS}-${VERSION}.tar.xz"
    EXTRACT_CMD="tar -xf"
fi

URL="https://ziglang.org/download/${VERSION}/${FILENAME}"
ARCHIVE_PATH="${INSTALL_DIR}/${FILENAME}"
EXTRACTED_DIR="${INSTALL_DIR}/zig-${ARCH}-${OS}-${VERSION}"

echo "Installing Zig ${VERSION} for ${OS}-${ARCH}"

# Create install directory
mkdir -p "${INSTALL_DIR}"

# Remove existing installation directory to ensure clean install
rm -rf "${ZIG_DIR}"

# Check if archive exists
if [ -f "${ARCHIVE_PATH}" ]; then
    echo "Archive already exists: ${ARCHIVE_PATH}"
fi

# Download if needed
if [ ! -f "${ARCHIVE_PATH}" ]; then
    echo "Downloading ${URL}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${URL}" -o "${ARCHIVE_PATH}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "${URL}" -O "${ARCHIVE_PATH}"
    else
        echo "Error: Neither curl nor wget found"
        exit 1
    fi

    if [ ! -f "${ARCHIVE_PATH}" ]; then
        echo "Error: Failed to download ${URL}"
        exit 1
    fi

    echo "Downloaded ${FILENAME}"
fi

# Extract archive
echo "Extracting ${FILENAME}"
if [ "$OS" = "windows" ]; then
    (cd "${INSTALL_DIR}" && ${EXTRACT_CMD} "${ARCHIVE_PATH}")
else
    ${EXTRACT_CMD} "${ARCHIVE_PATH}" -C "${INSTALL_DIR}"
fi

# Move extracted directory to expected location
if [ -d "${EXTRACTED_DIR}" ]; then
    mv "${EXTRACTED_DIR}" "${ZIG_DIR}"
fi

# Verify installation
if [ "$OS" = "windows" ]; then
    ZIG_BIN="${ZIG_DIR}/zig.exe"
else
    ZIG_BIN="${ZIG_DIR}/zig"
fi

if [ ! -f "${ZIG_BIN}" ]; then
    echo "Error: Zig binary not found after extraction"
    exit 1
fi

# Test Zig installation
INSTALLED_VERSION=$("${ZIG_BIN}" version)
if [ -z "${INSTALLED_VERSION}" ]; then
    echo "Error: Zig installation failed verification"
    exit 1
fi

# Add to PATH for GitHub Actions
echo "${ZIG_DIR}" >> "$GITHUB_PATH"

echo "Successfully installed Zig ${INSTALLED_VERSION}"

