#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="$ANDROID_HOME/build-tools/35.0.0"
owner=com.anxiong.nicevideos.mobile
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard
adb shell settings put system screen_off_timeout 1800000
diagnose() {
  adb shell dumpsys window windows > "$RUNNER_TEMP/nice-ui-state.txt" || true
  adb exec-out screencap -p > "$RUNNER_TEMP/nice-ui-state.png" || true
}
trap diagnose ERR

# Preserve a running 1.3.10 installation for a real package-manager update at the end.
old="$RUNNER_TEMP/original-mobile.apk"
if [[ "$MOBILE_ID" != "$owner" ]]; then
  previous="$RUNNER_TEMP/previous-test-signed.apk"
  "$sdk/apksigner" sign --ks "$NICE_MOBILE_STORE_FILE" --ks-key-alias nice-mobile \
    --ks-pass env:NICE_MOBILE_STORE_PASS --out "$previous" "$old"
  old="$previous"
fi
adb install -r "$old"
adb shell am start -W -n "$owner/com.anxiong.nicevideos.MainActivity"
adb shell input keyevent KEYCODE_HOME
adb install -r NiceVideos-Mobile.apk
adb shell pm path "$owner"
adb shell pm path "$MOBILE_ID"
shopt -s nullglob
install_tests() {
  local apks=(app/build/outputs/apk/androidTest/mobile/*.apk)
  [[ ${#apks[@]} -eq 1 ]]
  adb install -t -r "${apks[0]}"
}
instrument() {
  adb shell am instrument -w -r -e class "$2" "$1.test/androidx.test.runner.AndroidJUnitRunner" | tr -d '\r' | tee "$3"
  grep -Eq '^OK \([0-9]+ tests?\)' "$3"
}
install_tests
out="$RUNNER_TEMP/nice-mobile-api35-result.txt"
instrument "$MOBILE_ID" 'com.anxiong.nicevideos.ServerDownloadTest,com.anxiong.nicevideos.DirectDownloadTest,com.anxiong.nicevideos.ServerUploadTest,com.anxiong.nicevideos.BatchDeleteDownloadsTest' "$out"
for suite in ServerDownloadTest DirectDownloadTest ServerUploadTest BatchDeleteDownloadsTest; do
  grep -Fq "class=com.anxiong.nicevideos.$suite" "$out"
done
if [[ "$MOBILE_ID" != "$owner" ]]; then
  ./gradlew -PtestMobile :app:assembleMobile :app:assembleMobileAndroidTest
  adb install -r app/build/outputs/apk/mobile/app-mobile.apk
  install_tests
  instrument "$owner" 'com.anxiong.nicevideos.BatchDeleteDownloadsTest' "$RUNNER_TEMP/owner-upgrade-test.txt"
fi
