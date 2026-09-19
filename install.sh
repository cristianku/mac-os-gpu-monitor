#!/usr/bin/env bash
set -euo pipefail

APP_NAME="gpu-monitor"
SOURCE="Sources/mac-gpu-monitor/main.swift"
BUILD_DIR="build"
PREFIX="${PREFIX:-/usr/local}"
DESTINATION="${PREFIX}/bin/${APP_NAME}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: mac-os-gpu-monitor supports macOS only." >&2
  exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc was not found." >&2
  echo "Install Apple Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

mkdir -p "${BUILD_DIR}"

echo "Building ${APP_NAME}..."
swiftc -O -framework IOKit -framework Foundation "${SOURCE}" -o "${BUILD_DIR}/${APP_NAME}"

echo "Installing to ${DESTINATION}..."
if [[ -w "$(dirname "${DESTINATION}")" ]]; then
  mkdir -p "$(dirname "${DESTINATION}")"
  install -m 755 "${BUILD_DIR}/${APP_NAME}" "${DESTINATION}"
else
  sudo mkdir -p "$(dirname "${DESTINATION}")"
  sudo install -m 755 "${BUILD_DIR}/${APP_NAME}" "${DESTINATION}"
fi

echo
echo "Installed successfully."
echo "Run: gpu-monitor"
echo "For AMD/Hackintosh driver counters: gpu-monitor --raw"
