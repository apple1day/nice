#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v swift >/dev/null || { echo '需要 Swift 5.9+；Mac 请先选择完整 Xcode。'; exit 1; }
# Exercise the production retirement helper with real reference destruction,
# blocking fake native resources, late owners, and the real main dispatch queue.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nice-teardown.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/Sources/NiceVideos" "$scratch/Tests/NiceVideosTests"
cp NiceVideos/PlaybackResourceRetirement.swift "$scratch/Sources/NiceVideos/"
cp Tests/PlayerTeardownTests.swift "$scratch/Tests/NiceVideosTests/"
cat > "$scratch/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NiceTeardownChecks", targets: [
    .target(name: "NiceVideos"),
    .testTarget(name: "NiceVideosTests", dependencies: ["NiceVideos"])
])
PACKAGE
swift test --package-path "$scratch" --jobs "${SWIFT_TEST_JOBS:-2}"
