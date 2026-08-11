#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
BUILD_DIR="${PROJECT_DIR}/.build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/Screen Sharing Dictation.app"
EXECUTABLE_PATH="${APP_PATH}/Contents/MacOS/ScreenSharingDictation"

mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

xcrun swiftc \
  -parse-as-library \
  -O \
  -framework AppKit \
  -lsqlite3 \
  "${PROJECT_DIR}/Sources/ScreenSharingDictation/main.swift" \
  -o "${BUILD_DIR}/ScreenSharingDictation"

if [[ -d "${APP_PATH}" ]]; then
  rm -rf -- "${APP_PATH}"
fi

mkdir -p "${APP_PATH}/Contents/MacOS"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"
cp "${BUILD_DIR}/ScreenSharingDictation" "${EXECUTABLE_PATH}"
chmod 755 "${EXECUTABLE_PATH}"

# An ad-hoc signature is sufficient for a locally built helper. Rebuilding the
# app may require re-approving Automation or Accessibility permissions.
codesign --force --deep --sign - "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}"

print "Built ${APP_PATH}"
