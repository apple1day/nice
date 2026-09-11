#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
bash Tests/generate-fixtures.sh
bash setup.sh
DEVICE_ID="${DEVICE_ID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            print(device["udid"])
            sys.exit(0)
sys.exit("请在 Xcode 中安装一个 iPhone 模拟器 runtime")
')}"
xcodebuild -workspace NiceVideos.xcworkspace -scheme NiceVideos \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "${DERIVED_DATA_PATH:-./DerivedData}" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
