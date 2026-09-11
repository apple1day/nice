#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo '需要 Swift 编译器。'; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
swiftc NiceVideos/LocalRemovalTransaction.swift tools/watch-delete-smoke/main.swift -o "$work/watch-delete-smoke"
"$work/watch-delete-smoke"
