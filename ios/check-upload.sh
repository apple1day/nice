#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/Sources/NiceVideos" "$work/Tests/NiceVideosTests"
cp NiceVideos/LocalUploadTypes.swift "$work/Sources/NiceVideos/"
cp Tests/LocalUploadPolicyTests.swift "$work/Tests/NiceVideosTests/"
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "UploadPolicyRegression", targets: [
    .target(name: "NiceVideos"),
    .testTarget(name: "NiceVideosTests", dependencies: ["NiceVideos"])
])
PACKAGE
swift test --package-path "$work" --jobs 2
