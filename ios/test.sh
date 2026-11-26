#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# The CI job runs the field regressions first so codec and playback failures
# are available before the longer UI suite. A plain invocation runs everything.
motion_tests=(
  NiceVideosTests/PickedFilePlaybackTests/testOfflineCopyOfFull8KMain10PreservesAudioAndMovingPanoramaAfterSeeking
  NiceVideosTests/SBSPlaybackEngineTests/testKnownUndecodableAppleTrackSkipsSecondAutomaticOpenButAllowsRetryAndNextFile
  NiceVideosTests/SBSPlaybackEngineTests/testSoftwareDecoderPolicyKeepsPositionAndPauseWhenReturningToAutomaticVLC
  NiceVideosTests/SBSPlaybackEngineTests/testVLCChangesPositionToLastScrubAsReopenedPanoramaStarts
  NiceVideosTests/StereoFrameDecodeTests/testReducedOutputResumes8KSourceWithSmallerStereoBuffers
  NiceVideosTests/StereoFrameDecodeTests/testForcedSoftwareDecodesMain10FullHeight8KWithMovingStereoEyes
  NiceVideosTests/StereoFrameDecodeTests/testFullHeight8K60PanoramaNegotiatesSmallerFramesAndChangesBothEyes
  NiceVideosTests/VLCHeadsetReplayTests/testLocal8KMovieChangesBothEyesAfterEachEOFReplay
)
case "${1:-all}" in
  all|vr-motion) bash Tests/generate-fixtures.sh; bash setup.sh ;;
  remaining-after-vr) test -d NiceVideos.xcworkspace && test -s Tests/Fixtures/vr8k-main10-hev1.mp4 ;;
  *) echo "Usage: $0 [all|vr-motion|remaining-after-vr]" >&2; exit 2 ;;
esac
set -- "${1:-all}"
case "$1" in
  vr-motion) set -- "${motion_tests[@]/#/-only-testing:}" ;;
  remaining-after-vr) set -- "${motion_tests[@]/#/-skip-testing:}" ;;
  all) set -- ;;
esac
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
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@" test
