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
  adb shell -T "ls -la '$old_dir' /sdcard/Download/NiceVideos; run-as $package sh -c 'ls -l shared_prefs files/legacy_download_restore; cat shared_prefs/download_options.xml shared_prefs/video_library.xml shared_prefs/legacy_download_migration.xml'" >&2 || true
  if adb shell uiautomator dump /sdcard/nice-upgrade-ui.xml >/dev/null 2>&1; then
    adb exec-out cat /sdcard/nice-upgrade-ui.xml | python3 -c 'import sys, xml.etree.ElementTree as ET; print([v for n in ET.parse(sys.stdin).iter("node") if (v := n.get("text"))])' >&2 || true
  fi
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
shared=/sdcard/Download/NiceVideos
fixture=app/build/generated/playbackFixtures/moving-sbs.mp4
echo "Exporting from the original installation without replacing the app or its files"
adb shell -T "mkdir -p '$shared' && test ! -e '$shared/Upgrade test.mp4' && test ! -e '$shared/Upgrade test (1).mp4'"
printf 'Original unrelated video' > "$work/occupied"
adb push "$work/occupied" "$shared/Upgrade test.mp4"
adb exec-out "run-as $package cat shared_prefs/video_library.xml" > "$work/original-library.xml"
adb exec-out "run-as $package cat shared_prefs/video_positions.xml" > "$work/original-positions.xml"
python3 tools/legacy_download_backup.py export
adb exec-out "cat '$shared/Upgrade test (1).mp4'" | cmp "$fixture" -
python3 tools/legacy_download_backup.py export
adb exec-out "cat '$shared/Upgrade test.mp4'" | cmp "$work/occupied" -
adb exec-out "cat '$shared/Upgrade test (1).mp4'" | cmp "$fixture" -
adb shell -T "test ! -e '$shared/Upgrade test (2).mp4'"
adb exec-out "run-as $package cat shared_prefs/video_library.xml" | cmp "$work/original-library.xml" -
adb exec-out "run-as $package cat shared_prefs/video_positions.xml" | cmp "$work/original-positions.xml" -
echo "Verified the shared export, repeat export, occupied filename, and unchanged old catalog and bookmarks."
adb shell -T "rm '$shared/Upgrade test.mp4' '$shared/Upgrade test (1).mp4'"
echo "Checking that the VR player installs alongside the original app"
vr_package="$package.vrplayer"
adb install -r NiceVideos-VR.apk
adb shell am start -W -n "$vr_package/com.anxiong.nicevideos.MainActivity"
adb shell pm path "$vr_package" | grep -q 'package:'
adb shell pm path "$package" | grep -q 'package:'
adb exec-out "run-as $package cat shared_prefs/video_library.xml" | cmp "$work/original-library.xml" -
adb shell am force-stop "$vr_package"
echo "Verifying the backup and restore of DownloadManager job $job"
python3 tools/legacy_download_backup.py backup "$work/backup"
cmp "$fixture" "$work/backup/Movies/$disk"
adb uninstall "$package"
adb install app/build/outputs/apk/debug/app-debug.apk
python3 tools/legacy_download_backup.py restore "$work/backup"
adb exec-out "run-as $package cat files/legacy_download_restore/$disk" | cmp "$fixture" -
adb shell am start -W -n "$package/com.anxiong.nicevideos.MainActivity"
for ((attempt=0; attempt<45; attempt++)); do
  if adb shell -T "test -s '/sdcard/Download/NiceVideos/Upgrade test.mp4'" &&
     adb shell -T "run-as $package test ! -e files/legacy_download_restore/$disk"; then break; fi
  sleep 1
done
adb exec-out "cat '/sdcard/Download/NiceVideos/Upgrade test.mp4'" | cmp app/build/generated/playbackFixtures/moving-sbs.mp4 -
adb shell -T "run-as $package test ! -e files/legacy_download_restore/$disk"
adb shell -T "test ! -e '$old_dir/$disk'"
adb shell -T "run-as $package cat shared_prefs/video_positions.xml" | grep -q 12500
adb shell -T "run-as $package cat shared_prefs/video_library.xml" > "$work/catalog.xml"
python3 - "$work/catalog.xml" "$movie" <<'PY'
import json, sys, xml.etree.ElementTree as ET
row = json.loads(ET.parse(sys.argv[1]).find(f"string[@name='movie.{sys.argv[2]}']").text)
assert row['publicDownload'] and row['favorite'] and row['job'] == -1, row
PY
echo "Verified old APK backup, fresh install, catalog restore and migration into shared Downloads."
