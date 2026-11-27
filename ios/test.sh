#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# Run storage and playback regressions before the longer UI suite.
# A plain invocation still runs every test.
field_tests=(
  NiceVideosTests/FullHeightVRPlaybackTests/testAutomatic8K60HeadsetPlaybackAdvancesAfterPauseAndSeek
  NiceVideosTests/DirectHEVCFrameTests
  NiceVideosTests/VLCFrameLossWatchTests
  NiceVideosTests/VLCHeadsetReplayTests/testSustainedFullHeight8K60VLCToMetalCadence
  NiceVideosUITests/MovingMovieUITests/testPickedPanoramaCanLookAroundRecenterAndPlayInBothEyes
  NiceVideosUITests/UploadFilesPickerUITests
  NiceVideosUITests/MissingLocalRecordUITests
  NiceVideosTests/PickedFileUploadIntegrationTests
  NiceVideosTests/PickedUploadDocumentTests
  NiceVideosTests/LocalUploadManagerTests
  NiceVideosTests/BatchDeletionTests/testClearMissingHistoryRefreshesRestoredMoviesAndOnlyForgetsAbsentConfirmedEntries
  NiceVideosTests/BatchDeletionTests/testRemoveMissingRecordSkipsNewDownloadAttemptAndPreservesUserMovedFile
  NiceVideosTests/BatchDeletionTests/testMissingCleanupKeepsHistoryAndBookmarksIfSavingFails
  NiceVideosTests/FilesIntegrationTests
  NiceVideosTests/SharedDownloadStorageTests
  NiceVideosTests/SharedDownloadAvailabilityTests
  NiceVideosTests/LibraryPerformanceTests/testFilesRemovalKeepsVisibleHistoryButExcludesItFromPlaybackAndUpload
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
  vr-motion) set -- "${field_tests[@]/#/-only-testing:}" ;;
  remaining-after-vr) set -- "${field_tests[@]/#/-skip-testing:}" ;;
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
