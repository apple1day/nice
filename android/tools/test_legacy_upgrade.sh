#!/usr/bin/env bash
# Exercise the published 1.2.0 debug APK and the backup helper on a disposable CI emulator.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "$(adb shell getprop ro.kernel.qemu | tr -d '\r')" == 1 ]] || exit 2
package=com.anxiong.nicevideos.vr.preview
movie=19774e38-49f4-46c7-a378-3bff17047e87
old_dir="/sdcard/Android/data/$package/files/Movies"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
diagnose() {
  echo "Upgrade check failed at line $1" >&2
  adb shell -T "id; ls -ld /sdcard/Android/data/$package '$old_dir' /sdcard/Download/NiceVideos" >&2 || true
  adb logcat -d -t 120 'AndroidRuntime:E' 'ActivityTaskManager:E' 'MediaProvider:W' '*:S' >&2 || true
}
trap 'diagnose "$LINENO"' ERR
curl --fail --location --retry 3 --silent --show-error \
  'https://raw.githubusercontent.com/apple1day/nice/95d516f142b09c1d06cf0781d23c39b00ef6f894/android/NiceVideos.apk' -o "$work/old.apk"
echo "fb5f880ab28b392a1797feb4dac314888880400aace985ede50e2d80440662d0  $work/old.apk" | sha256sum -c -
adb uninstall "$package" >/dev/null 2>&1 || true
adb install "$work/old.apk"
# Seed only this disposable emulator. ADB's shell user can see the user-0
# emulated storage mount. run-as is needed only for the app's internal XML.
echo "Creating private-layout movie and preference fixtures in the old installation"
adb shell am force-stop "$package"
adb shell -T "mkdir -p '$old_dir' && test -d '$old_dir'"
adb push app/build/generated/playbackFixtures/moving-sbs.mp4 "$old_dir/$movie.mp4"
adb shell -T "test -s '$old_dir/$movie.mp4'"
adb shell -T "run-as $package mkdir -p shared_prefs"
bytes=$(wc -c < app/build/generated/playbackFixtures/moving-sbs.mp4)
adb shell -T "run-as $package sh -c 'cat > shared_prefs/video_library.xml'" <<XML
<map><string name="movie.$movie">{"id":"$movie","name":"Upgrade test.mp4","disk":"$movie.mp4","bytes":$bytes,"source":"https://example.invalid/test.mp4","job":321,"favorite":true,"state":"ready"}</string></map>
XML
bookmark=$(python3 - "$package" "$movie" <<'PYCODE'
import hashlib, sys, uuid
uri = f'content://{sys.argv[1]}.offline/{sys.argv[2]}'
print(uuid.UUID(bytes=hashlib.md5(uri.encode()).digest(), version=3))
PYCODE
)
adb shell -T "run-as $package sh -c 'cat > shared_prefs/video_positions.xml'" <<XML
<map><long name="$bookmark" value="12500"/></map>
XML
python3 tools/legacy_download_backup.py backup "$work/backup"
adb uninstall "$package"
adb install app/build/outputs/apk/debug/app-debug.apk
python3 tools/legacy_download_backup.py restore "$work/backup"
adb shell am start -W -n "$package/com.anxiong.nicevideos.MainActivity"
for ((attempt=0; attempt<45; attempt++)); do
  if adb shell -T "test -s '/sdcard/Download/NiceVideos/Upgrade test.mp4'" &&
     adb shell -T "test ! -e '$old_dir/$movie.mp4'"; then break; fi
  sleep 1
done
adb exec-out "cat '/sdcard/Download/NiceVideos/Upgrade test.mp4'" | cmp app/build/generated/playbackFixtures/moving-sbs.mp4 -
adb shell -T "test ! -e '$old_dir/$movie.mp4'"
adb shell -T "run-as $package cat shared_prefs/video_positions.xml" | grep -q 12500
adb shell -T "run-as $package cat shared_prefs/video_library.xml" > "$work/catalog.xml"
python3 - "$work/catalog.xml" "$movie" <<'PY'
import json, sys, xml.etree.ElementTree as ET
row = json.loads(ET.parse(sys.argv[1]).find(f"string[@name='movie.{sys.argv[2]}']").text)
assert row['publicDownload'] and row['favorite'] and row['job'] == -1, row
PY
echo "Verified old APK backup, fresh install, catalog restore and migration into shared Downloads."
