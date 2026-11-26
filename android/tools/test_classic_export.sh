#!/usr/bin/env bash
# Destructive setup is restricted to a disposable GitHub Actions emulator.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || exit 2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
package=com.anxiong.nicevideos
shared=/sdcard/Download/NiceVideos
fixture=app/build/generated/playbackFixtures/moving-sbs.mp4
signer="$ANDROID_HOME/build-tools/35.0.0/apksigner"
release=app/build/outputs/apk/release/app-release-unsigned.apk
sign_for_test() {
  "$signer" sign --ks "$HOME/.android/debug.keystore" --ks-key-alias androiddebugkey \
    --ks-pass pass:android --key-pass pass:android --out "$2" "$1"
  "$signer" verify "$2"
}
sign_for_test "$release" "$work/test-signed-update.apk"
check_catalog() {
  adb exec-out "run-as $package cat shared_prefs/video_library.xml" | cmp "$work/catalog" -
  adb exec-out "run-as $package cat shared_prefs/video_positions.xml" | cmp "$work/positions" -
}
read_source() {
  if adb shell -T "test -r '$private_source'"; then
    adb exec-out "cat '$private_source'"
  else
    adb exec-out "run-as $package cat '$private_source'"
  fi
}
# These immutable copies shipped as 1.0.0 with distinct certificates.
while read -r commit digest <&3; do
  git show "$commit:android/NiceVideos.apk" > "$work/original.apk"
  echo "$digest  $work/original.apk" | sha256sum -c -
  adb uninstall "$package" >/dev/null 2>&1 || true
  adb install "$work/original.apk"
  python3 tools/classic_export_fixture.py "$fixture" > "$work/movie"
  read -r movie disk job < "$work/movie"
  private_source="/sdcard/Android/data/$package/files/Movies/$disk"
  adb exec-out "run-as $package cat shared_prefs/video_library.xml" > "$work/catalog"
  adb exec-out "run-as $package cat shared_prefs/video_positions.xml" > "$work/positions"
  if adb install -r "$work/test-signed-update.apk" > "$work/update-result" 2>&1; then
    echo "Unexpectedly accepted a different signing identity" >&2; exit 1
  fi
  grep -F 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' "$work/update-result"
  check_catalog
  adb shell -T "mkdir -p '$shared'; test ! -e '$shared/Upgrade test.mp4' && test ! -e '$shared/Upgrade test (1).mp4'"
  printf 'unrelated movie' > "$work/occupied"
  adb push "$work/occupied" "$shared/Upgrade test.mp4"
  python3 tools/export_classic.py
  adb exec-out "cat '$shared/Upgrade test (1).mp4'" | cmp "$fixture" -
  python3 tools/export_classic.py
  adb exec-out "cat '$shared/Upgrade test.mp4'" | cmp "$work/occupied" -
  adb exec-out "cat '$shared/Upgrade test (1).mp4'" | cmp "$fixture" -
  adb shell -T "test ! -e '$shared/Upgrade test (2).mp4'"
  read_source | cmp "$fixture" -
  check_catalog
  adb shell -T "rm '$shared/Upgrade test.mp4' '$shared/Upgrade test (1).mp4'"
  echo "Verified direct USB export from published 83,397-byte code-1 APK $commit; its data and certificate were retained."
done 3<<'ORIGINALS'
f3a76ebf65f37bb2e6a997cace2a93ca21087e45 6507584a0e260f971a88d98b7f1226e249c76077fe613dfbf2de49775c95200b
1ef6092567f8faa0e3a3bc620011bf5314b33733 9b192ec696851c6e06c30b26032cd928e1cafd2fafad21ce46d0f7b661d75c03
ORIGINALS
# Separate upgrade test using the runner's key for both files. This key cannot update the shipped originals.
adb uninstall "$package"
sign_for_test "$work/original.apk" "$work/test-signed-original.apk"
adb install "$work/test-signed-original.apk"
python3 tools/classic_export_fixture.py "$fixture" > "$work/movie"
adb install -r "$work/test-signed-update.apk"
adb shell -T "dumpsys package $package" | grep 'versionCode=2 '
folder=/sdcard/Download/ClassicExportCheck
adb shell -T "mkdir -p '$folder' && test ! -e '$folder/Upgrade test.mp4'"
python3 tools/classic_export_fixture.py --export-after-update
for ((i=0; i<30; i++)); do
  if adb shell -T "test -s '$folder/Upgrade test.mp4'"; then break; fi
  sleep 1
done
adb exec-out "cat '$folder/Upgrade test.mp4'" | cmp "$fixture" -
echo 'Verified same-key in-place update: the old favorite and movie remained available and the new release exported the original bytes.'
