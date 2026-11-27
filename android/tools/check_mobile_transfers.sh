#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
adb install -r NiceVideos-Mobile.apk
shopt -s nullglob
tests=(app/build/outputs/apk/androidTest/mobile/*.apk)
[[ ${#tests[@]} -eq 1 ]]
adb install -t -r "${tests[0]}"
out="$RUNNER_TEMP/nice-mobile-api35-result.txt"
adb shell am instrument -w -r \
  -e class 'com.anxiong.nicevideos.ServerDownloadTest,com.anxiong.nicevideos.DirectDownloadTest,com.anxiong.nicevideos.ServerUploadTest' \
  com.anxiong.nicevideos.mobile.test/androidx.test.runner.AndroidJUnitRunner | tr -d '\r' | tee "$out"
grep -Eq '^OK \([0-9]+ tests?\)' "$out"
for class in ServerDownloadTest DirectDownloadTest ServerUploadTest; do
  grep -Fq "class=com.anxiong.nicevideos.$class" "$out"
done
