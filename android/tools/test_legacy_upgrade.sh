#!/usr/bin/env bash
# Exercise the published 1.2.0 debug APK and the backup helper on a disposable CI emulator.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || exit 2
package=com.anxiong.nicevideos.vr.preview
old_dir="/sdcard/Android/data/$package/files/Movies"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
diagnose() {
  echo "Upgrade check failed at line $1" >&2
  adb shell -T "id; ls -ld /sdcard/Android/data/$package '$old_dir' /sdcard/Download/NiceVideos" >&2 || true
  adb shell -T "run-as $package sh -c 'ls -l shared_prefs; cat shared_prefs/video_library.xml'" >&2 || true
  adb logcat -d -t 120 'AndroidRuntime:E' 'ActivityTaskManager:E' 'MediaProvider:W' '*:S' >&2 || true
}
trap 'diagnose "$LINENO"' ERR
curl --fail --location --retry 3 --silent --show-error \
  'https://raw.githubusercontent.com/apple1day/nice/95d516f142b09c1d06cf0781d23c39b00ef6f894/android/NiceVideos.apk' -o "$work/old.apk"
echo "fb5f880ab28b392a1797feb4dac314888880400aace985ede50e2d80440662d0  $work/old.apk" | sha256sum -c -
adb uninstall "$package" >/dev/null 2>&1 || true
adb install "$work/old.apk"
echo "Downloading a video using the shipped 1.2.0 app"
python3 tools/seed_upgrade_movie.py app/build/generated/playbackFixtures/moving-sbs.mp4 > "$work/old-movie"
read -r movie disk job < "$work/old-movie"
echo "Verifying the backup and restore of DownloadManager job $job"
python3 tools/legacy_download_backup.py backup "$work/backup"
adb uninstall "$package"
adb install app/build/outputs/apk/debug/app-debug.apk
python3 tools/legacy_download_backup.py restore "$work/backup"
adb shell am start -W -n "$package/com.anxiong.nicevideos.MainActivity"
for ((attempt=0; attempt<45; attempt++)); do
  if adb shell -T "test -s '/sdcard/Download/NiceVideos/Upgrade test.mp4'" &&
     adb shell -T "run-as $package test ! -e files/legacy_download_restore/$disk"; then break; fi
  sleep 1
done
adb exec-out "cat '/sdcard/Download/NiceVideos/Upgrade test.mp4'" | cmp app/build/generated/playbackFixtures/moving-sbs.mp4 -
adb shell -T "run-as $package test ! -e files/legacy_download_restore/$disk"
adb shell -T "run-as $package cat shared_prefs/video_positions.xml" | grep -q 12500
adb shell -T "run-as $package cat shared_prefs/video_library.xml" > "$work/catalog.xml"
python3 - "$work/catalog.xml" "$movie" <<'PY'
import json, sys, xml.etree.ElementTree as ET
row = json.loads(ET.parse(sys.argv[1]).find(f"string[@name='movie.{sys.argv[2]}']").text)
assert row['publicDownload'] and row['favorite'] and row['job'] == -1, row
PY
echo "Verified old APK backup, fresh install, catalog restore and migration into shared Downloads."
