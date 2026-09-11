#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v swift >/dev/null || { echo '需要 Swift 工具链'; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/Sources/NiceVideos" "$work/Tests/NiceVideosTests"
cp NiceVideos/LocalPlaybackPlaylist.swift NiceVideos/PlaybackControlsState.swift "$work/Sources/NiceVideos/"
cp Tests/LocalPlaylistTests.swift "$work/Tests/NiceVideosTests/"
cat > "$work/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PlaylistRegression", targets: [
    .target(name: "NiceVideos"),
    .testTarget(name: "NiceVideosTests", dependencies: ["NiceVideos"])
])
PACKAGE
swift test --package-path "$work" --jobs 2
