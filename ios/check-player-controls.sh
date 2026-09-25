#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v swift >/dev/null || { echo '需要 Swift 5.9+；Mac 请先选择完整 Xcode。'; exit 1; }
# Run the exact same XCTest source as the app, without UIKit, CocoaPods, network,
# generated Xcode projects, or sleeping for the real auto-hide interval.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nice-controls.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/Sources/NiceVideos" "$scratch/Tests/NiceVideosTests"
cp NiceVideos/PlaybackControlsState.swift "$scratch/Sources/NiceVideos/"
cp Tests/PlaybackControlsTests.swift "$scratch/Tests/NiceVideosTests/"
cat > "$scratch/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NiceControlsChecks", targets: [
    .target(name: "NiceVideos"),
    .testTarget(name: "NiceVideosTests", dependencies: ["NiceVideos"])
])
PACKAGE
swift test --package-path "$scratch" --jobs "${SWIFT_TEST_JOBS:-2}"
