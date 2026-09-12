#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo '需要 Swift 编译器。'; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
swiftc NiceVideos/BatchSelection.swift tools/batch-selection-smoke/main.swift -o "$work/batch-selection"
"$work/batch-selection"
