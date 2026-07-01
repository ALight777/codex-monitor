#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-notch-regression.XXXXXX")"
trap 'rm -rf "${BUILD_DIR}"' EXIT

if [[ ! -x /usr/bin/sqlite3 ]]; then
  echo "Missing /usr/bin/sqlite3, cannot run codex监测 regression tests" >&2
  exit 1
fi

swift build -c release --build-path "${BUILD_DIR}/package-build"

swiftc \
  -swift-version 6 \
  "${ROOT_DIR}/Sources/CodexNotch/Models.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/AppInfo.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/Formatters.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/SnapshotOutputFormatter.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/DisplayRedactor.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/Shell.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/KeychainStore.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/SecretStore.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/CodexRadarModels.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/CodexRadarClient.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/CodexNotchSettings.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/CodexUsageStore.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/BalanceMonitorModels.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/BalanceAPIClient.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/RemoteMonitorModels.swift" \
  "${ROOT_DIR}/Sources/CodexNotch/CLIProxyAPIClient.swift" \
  "${ROOT_DIR}/Tests/CodexNotchRegressionTests/main.swift" \
  -o "${BUILD_DIR}/CodexNotchRegressionTests"

"${BUILD_DIR}/CodexNotchRegressionTests"
