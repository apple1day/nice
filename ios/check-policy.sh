#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swiftc NiceVideos/OfflineMediaPolicy.swift tools/policy-smoke/main.swift -o "$work/check"
"$work/check"
