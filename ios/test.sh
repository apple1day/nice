#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo '请先执行 brew install xcodegen'; exit 1; }
xcodegen generate
DEVICE_ID="${DEVICE_ID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            print(device["udid"])
            sys.exit(0)
sys.exit("没有可用 iPhone 模拟器，请在 Xcode 中安装 iOS Simulator runtime")
')}"
xcodebuild -project NiceVideos.xcodeproj -scheme NiceVideos \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "${DERIVED_DATA_PATH:-./DerivedData}" \
  CODE_SIGNING_ALLOWED=NO test
