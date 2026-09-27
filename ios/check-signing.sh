#!/usr/bin/env bash
# Run the same Foundation-only XCTest suite on Linux or macOS, without iOS SDKs.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
command -v swift >/dev/null || { echo "Swift 5.9+ is required" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/nice-signing-tests.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Sources/SigningCore" "$tmp/Tests/SigningCoreTests"
cp "$root/NiceVideos/SigningStatus.swift" "$root/NiceVideos/SigningReminder.swift" "$tmp/Sources/SigningCore/"
cp "$root/Tests/SigningStatusTests.swift" "$root/Tests/SigningReminderTests.swift" "$tmp/Tests/SigningCoreTests/"
cat > "$tmp/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SigningCore", platforms: [.macOS(.v13)], targets: [
    .target(name: "SigningCore"),
    .testTarget(name: "SigningCoreTests", dependencies: ["SigningCore"])
])
PACKAGE
swift test --package-path "$tmp" --jobs 2
