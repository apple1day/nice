#!/usr/bin/env python3
"""Export or back up/restore Nice VR 1.2 downloads on your own USB-debugging device (Android owner profile)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET


PACKAGE = "com.anxiong.nicevideos.vr.preview"
MOVIES = "/sdcard/Android/data/" + PACKAGE + "/files/Movies"
PUBLIC = "/sdcard/Download/NiceVideos"
STAGING = "files/legacy_download_restore"
PREFS = ("video_positions.xml", "vr_gestures.xml", "video_library.xml")  # Commit catalog last.
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
MOVIE = re.compile(UUID + r"\.[a-z0-9]{1,10}")
FORMAT = "NiceVideos-VR-1.2-legacy-v1"
MARKER = ".nice-backup-in-progress"
BLOCK = 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Device:
    def __init__(self, serial):
        self.adb = ["adb"] + (["-s", serial] if serial else [])
        self.external = self.run

    def run(self, command, **kwargs):
        # -T keeps binary streams intact. Shell v2 also propagates device exit status.
        return subprocess.run(self.adb + ["shell", "-T", command], check=True, **kwargs)

    def app(self, script, **kwargs):
        return self.run("run-as " + PACKAGE + " sh -c " + shlex.quote(script), **kwargs)

    def file_command(self, path, script, **kwargs):
        # Private preferences require run-as. USB shell and run-as can see different
        # emulated-storage mounts even though both are addressing the owner profile.
        method = self.external if path.startswith(MOVIES.rsplit("/", 1)[0] + "/") else self.app
        return method(script, **kwargs)

    def text(self, script, path=""):
        return self.file_command(path, script, stdout=subprocess.PIPE).stdout.decode().strip()

    def select_movies_access(self, restoring):
        parent = MOVIES.rsplit("/", 1)[0]
        for probe in (MOVIES,) if restoring else (MOVIES, parent):
            for method in (self.run, self.app):
                try:
                    test = f"test -d {probe} && ls -A {probe} >/dev/null"
                    if probe == parent:
                        # A readable parent proves an absent Movies directory only when
                        # its own directory listing confirms that absence.
                        test += f" && ! ls -A1 {parent} | grep -Fx Movies >/dev/null"
                    if restoring:
                        test += f" && t=$(mktemp {probe}/.nice-write-XXXXXX) && rm \"$t\""
                    method(test,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except subprocess.CalledProcessError:
                    continue
                self.external = method
                return True
        return False

    def check_installation(self, restoring):
        owner = self.run("am get-current-user", stdout=subprocess.PIPE).stdout.strip()
        require(owner == b"0", "Switch to the Android owner profile (user 0).")
        self.app("true")
        package_info = self.run("dumpsys package " + PACKAGE, stdout=subprocess.PIPE).stdout
        version = re.search(rb"\bversionCode=(\d+)\b", package_info)
        require(version, "Cannot determine the installed Nice app version.")
        require(int(version[1]) >= 4 if restoring else int(version[1]) == 3,
                "Backup needs the old 1.2.0 trial (code 3); restore needs the updated app (code 4 or newer).")

    def stop(self, restoring):
        self.check_installation(restoring)
        self.run("am force-stop " + PACKAGE)

    def digest(self, path):
        # Paths passed here consist exclusively of locally constructed, allowlisted names.
        raw = self.text("if [ -L {0} ]; then exit 1; elif [ -f {0} ]; then "
                        "stat -c %s {0} && sha256sum {0}; elif [ -e {0} ]; then exit 1; fi".format(path), path)
        if not raw:
            return None
        lines = raw.splitlines()
        return {"bytes": int(lines[0]), "sha256": lines[1].split()[0]}

    def movies(self, directory=MOVIES):
        parent = directory.rsplit("/", 1)[0]
        # 'test -d' alone reports false on EACCES too. Require a readable parent
        # before accepting an absent Movies directory as empty.
        result = self.text(f"if [ -d {directory} ]; then ls -A1 {directory}; "
                           f"else ls -A {parent} >/dev/null; fi", directory + "/")
        names = result.splitlines()
        require(all(MOVIE.fullmatch(n) for n in names),
                "Unexpected files in the old Movies directory. Inspect them before backing up.")
        return sorted(names)

    def pref(self, name):
        # Android SharedPreferences restores its .bak file first if a write was interrupted.
        path = "shared_prefs/" + name
        result = self.text(f"if [ -f {path}.bak ]; then echo {path}.bak; "
                           f"elif [ -f {path} ]; then echo {path}; fi")
        return result or None


def file_digest(path):
    require(path.is_file() and not path.is_symlink(), f"Missing or unsafe file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(BLOCK), b""):
            digest.update(block)
    return {"bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def bytes_digest(value):
    return {"bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}


def check_catalog(data, movies, restoring=False, internal=False):
    require(len(data) < 32 * 1024 * 1024, "Unexpectedly large preferences file.")
    root = ET.fromstring(data)
    require(root.tag == "map", "Invalid SharedPreferences XML.")
    for node in root:
        key = node.get("name", "")
        if not key.startswith("movie."):
            continue
        require(node.tag == "string", "Invalid movie preference type.")
        e = json.loads(node.text)
        require(re.fullmatch(UUID, e["id"]) and key == "movie." + e["id"], "Invalid catalog ID.")
        require(not e.get("publicDownload") and not e.get("publicUri"),
                "This helper is only for the old private download layout.")
        disk = e.get("disk")
        if not disk:
            continue  # External document references are metadata only.
        require(MOVIE.fullmatch(disk), "Unexpected private filename in catalog.")
        state = e.get("state", "ready")
        require(state != "transfer", "An old download is active. Finish or cancel it in the old app first.")
        require(state in ("failed", "ready"), "Unrecognized download state.")
        if state == "ready":
            item = movies.get(disk)
            require(item and item["bytes"] > 0 and
                    (e.get("bytes", -1) < 0 or e["bytes"] == item["bytes"]),
                    f"Completed movie missing or incomplete: {disk}")
        if restoring:
            # IDs belong to the previous installation. Never remove or poll those jobs after restore.
            e["job"] = -1
            if internal and disk in movies:
                e["restoredPrivate"] = True
            node.text = json.dumps(e, ensure_ascii=False, separators=(",", ":"))
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def pull(device, remote, local, expected):
    if local.exists():
        require(file_digest(local) == expected, f"Existing backup file differs: {local}. Use a new folder.")
        return
    require(shutil.disk_usage(local.parent).free >= expected["bytes"], "Computer storage is full.")
    temporary = local.with_name("." + local.name + ".part")
    require(not temporary.is_symlink(), f"Unsafe temporary path: {temporary}")
    try:
        with temporary.open("wb") as out:
            device.file_command(remote, "cat " + remote, stdout=out)
            out.flush()
            os.fsync(out.fileno())
        require(file_digest(temporary) == expected, f"Copy did not match phone: {local.name}")
        temporary.replace(local)
    finally:
        temporary.unlink(missing_ok=True)


def ensure_dir(path):
    require(not path.is_symlink(), f"Refusing linked directory: {path}")
    path.mkdir(parents=True, exist_ok=True)


def backup(device, root):
    ensure_dir(root)
    marker = root / MARKER
    manifest = root / "manifest.json"
    require(not manifest.exists(), "This backup is complete; use a new directory for another snapshot.")
    if any(root.iterdir()):
        require(marker.is_file() and not marker.is_symlink() and marker.read_text() == FORMAT,
                "Choose an empty directory or a previous incomplete Nice backup.")
    else:
        marker.write_text(FORMAT)
    for name in ("prefs", "Movies"):
        ensure_dir(root / name)

    device.stop(restoring=False)
    require(device.select_movies_access(restoring=False),
            "USB debugging cannot read the old Movies directory. Keep the old app installed.")
    names = device.movies()
    info = {"format": FORMAT, "package": PACKAGE, "Movies": {}, "prefs": {}}
    for name in PREFS:
        source = device.pref(name)
        if source:
            item = device.digest(source)
            require(item and item["bytes"] < 32 * 1024 * 1024, f"Invalid preferences: {name}")
            pull(device, source, root / "prefs" / name, item)
            info["prefs"][name] = item
    catalog = root / "prefs/video_library.xml"
    if "video_library.xml" in info["prefs"]:
        # Reject active downloads before reading multi-GB files.
        sizes = {n: {"bytes": int(device.text("stat -c %s " + MOVIES + "/" + n, MOVIES + "/" + n))} for n in names}
        check_catalog(catalog.read_bytes(), sizes)
    for i, name in enumerate(names, 1):
        print(f"[{i}/{len(names)}] Verify and back up {name}", flush=True)
        source = MOVIES + "/" + name
        item = device.digest(source)
        require(item, f"Movie disappeared: {name}")
        pull(device, source, root / "Movies" / name, item)
        info["Movies"][name] = item
    if "video_library.xml" in info["prefs"]:
        check_catalog(catalog.read_bytes(), info["Movies"])
    require(names == device.movies(), "Movie list changed during backup.")
    for name in PREFS:
        source = device.pref(name)
        require((device.digest(source) if source else None) == info["prefs"].get(name),
                "The app changed during the backup. Keep it closed and retry in a new folder.")
    validate_backup(root, info, verify_bytes=False)
    tmp = root / ".manifest.tmp"
    require(not tmp.is_symlink(), "Unsafe manifest path.")
    with tmp.open("w") as out:
        json.dump(info, out, ensure_ascii=False, indent=2)
        out.flush()
        os.fsync(out.fileno())
    tmp.replace(manifest)
    marker.unlink()
    print(f"Verified backup complete: {len(names)} movie file(s). {manifest}")


def validate_backup(root, info, verify_bytes=True):
    require(info.get("format") == FORMAT and info.get("package") == PACKAGE, "Incompatible backup manifest.")
    for folder in ("Movies", "prefs"):
        directory = root / folder
        require(directory.is_dir() and not directory.is_symlink(), f"Invalid folder: {folder}")
        records = info[folder]
        require(isinstance(records, dict) and {p.name for p in directory.iterdir()} == set(records),
                f"File list doesn't match manifest: {folder}")
        for name, item in records.items():
            require(MOVIE.fullmatch(name) if folder == "Movies" else name in PREFS, "Invalid filename.")
            path = directory / name
            require(path.is_file() and not path.is_symlink(), f"Invalid backup file: {name}")
            if verify_bytes:
                require(file_digest(path) == item, f"Backup checksum mismatch: {name}")


def stage_path(directory, name):
    parent = directory.rsplit("/", 1)[0] if directory in (MOVIES, STAGING) else directory
    return parent + "/.nice-restore-" + name + ".part"


def upload(device, directory, name, expected, source=None, data=None, replace_empty=False):
    path = directory + "/" + name
    current = device.digest(path)
    if current == expected:
        return
    if current:
        require(replace_empty and current["bytes"] < 4096, f"Refusing to replace existing device file: {name}")
        existing = ET.fromstring(device.app("cat " + path, stdout=subprocess.PIPE).stdout)
        require(existing.tag == "map" and len(existing) == 0, f"Device already has settings: {name}")
    # A stable staging file outside Movies survives a lost USB connection without
    # entering the user's catalog or blocking the next restore.
    temp = stage_path(directory, name)
    try:
        script = f"umask 077; cat > {temp}"
        if source is not None:
            with source.open("rb") as stream:
                device.file_command(temp, script, stdin=stream)
        else:
            device.file_command(temp, script, input=data)
        require(device.digest(temp) == expected, f"Device copy failed verification: {name}")
        # Refuse to clobber files that appeared or changed after preflight.
        require(device.digest(path) == current, f"Destination changed during restore: {name}")
        device.file_command(path, ("mv -f " if current else "mv -n ") + temp + " " + path)
        require(device.digest(path) == expected, f"Restored file failed verification: {name}")
    finally:
        device.file_command(temp, "rm -f " + temp)


def restore(device, root):
    manifest = root / "manifest.json"
    require(not root.is_symlink() and manifest.is_file() and not manifest.is_symlink(), "Completed backup required.")
    info = json.loads(manifest.read_text())
    validate_backup(root, info)
    prefs = {}
    for name in PREFS:
        if name in info["prefs"]:
            data = (root / "prefs" / name).read_bytes()
            prefs[name] = check_catalog(data, info["Movies"], True) if name == "video_library.xml" else data
    device.stop(restoring=True)
    prior_directory = None
    for name in PREFS:
        path = device.pref(name)
        if path:
            require(not path.endswith(".bak"), "Target has an interrupted preferences update. Inspect the app first.")
            current = device.digest(path)
            allowed = [bytes_digest(prefs[name])] if name in prefs else []
            if name == "video_library.xml" and name in prefs:
                original = (root / "prefs" / name).read_bytes()
                internal_digest = bytes_digest(check_catalog(original, info["Movies"], True, True))
                if internal_digest != allowed[0]:
                    if current == internal_digest:
                        prior_directory = STAGING
                    elif current == allowed[0]:
                        prior_directory = MOVIES
                allowed.append(internal_digest)
            if current not in allowed:
                require(current["bytes"] < 4096, "Target already contains app settings.")
                xml = ET.fromstring(device.app("cat " + path, stdout=subprocess.PIPE).stdout)
                require(xml.tag == "map" and len(xml) == 0, "Target already contains library records or settings.")
    # Android 11+ provisions package-owned external directories through Context.
    # PREPARE_RESTORE creates Movies and finishes without starting downloads or migration.
    device.run("am start -W -n " + PACKAGE + "/com.anxiong.nicevideos.MainActivity "
               "-a com.anxiong.nicevideos.PREPARE_RESTORE", stdout=subprocess.DEVNULL)
    device.run("am force-stop " + PACKAGE)
    directory = prior_directory or MOVIES
    if directory == MOVIES and not device.select_movies_access(restoring=True):
        require(prior_directory is None,
                "The previously restored Movies directory is inaccessible. Keep both copies and retry.")
        directory = STAGING
    if directory == STAGING:
        device.app("mkdir -p " + directory)
        if "video_library.xml" in prefs:
            original = (root / "prefs/video_library.xml").read_bytes()
            prefs["video_library.xml"] = check_catalog(original, info["Movies"], True, True)
        print("Using the updated app’s internal migration staging folder.", flush=True)
    device.app("mkdir -p shared_prefs")
    require(set(device.movies(directory)) <= set(info["Movies"]), "Target contains other videos. Start with a fresh installation.")
    missing_bytes = 0
    for name, expected in info["Movies"].items():
        current = device.digest(directory + "/" + name)
        require(current is None or current == expected, f"Different movie exists on target: {name}")
        if current is None:
            # A disconnected run can leave its partial transfer in staging. The
            # bytes will be released when cat truncates that same staging file.
            stage = stage_path(directory, name)
            stage_size = int(device.text(f"if [ -f {stage} ]; then stat -c %s {stage}; else echo 0; fi", stage))
            missing_bytes += max(0, expected["bytes"] - stage_size)
    free = device.text("df -k " + directory, directory + "/").splitlines()[-1].split()
    require(int(free[-3]) * 1024 >= missing_bytes, "Not enough space to restore the videos.")
    for i, (name, item) in enumerate(info["Movies"].items(), 1):
        print(f"[{i}/{len(info['Movies'])}] Restore {name}", flush=True)
        upload(device, directory, name, item, source=root / "Movies" / name)
    for name, data in prefs.items():
        upload(device, "shared_prefs", name, bytes_digest(data), data=data, replace_empty=True)
    print("Verified restore complete. Open the updated Nice app to migrate the historical downloads.")


def export_title(title, private_name):
    # Match the app's public naming rules. Leave space within NAME_MAX for collision suffixes.
    name = re.sub(r'[\x00-\x1f\x7f\\/:*?"<>|]', "_", title).strip().strip(". ")
    name = name or private_name
    stem, suffix = os.path.splitext(name)
    if len(suffix.encode("utf-8")) > 32:
        stem, suffix = name, ""
    budget = 240 - len(suffix.encode("utf-8"))
    return stem.encode("utf-8")[:budget].decode("utf-8", errors="ignore"), suffix


# Executed entirely on the phone. Only the source reader may need run-as. The regular USB
# shell owns the public writes. All dynamic strings are positional parameters, never shell code.
EXPORT_COPY = r"""
set -eu
folder=$1
stem=$2
suffix=$3
source=$4
size=$5
digest=$6
package=$7
umask 077
test ! -L "$folder"
mkdir -p "$folder"
cd "$folder"
part=''
reserved=''
identity=''
cleanup() {
    if [ -n "$part" ]; then rm -f "$part"; fi
    # Remove only the same zero-byte reservation if publication or the USB session failed.
    if [ -n "$reserved" ] && [ -n "$identity" ] && [ ! -L "$reserved" ] &&
       [ "$(stat -c '%d:%i:%s' "$reserved" 2>/dev/null)" = "$identity" ]; then rm -f "$reserved"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
matches() {
    [ ! -L "$1" ] && [ -f "$1" ] && [ "$(stat -c %s "$1")" = "$size" ] || return 1
    actual=$(sha256sum < "$1") && [ "${actual%% *}" = "$digest" ]
}
index=0
while :; do
    if [ "$index" = 0 ]; then name="$stem$suffix"; else name="$stem ($index)$suffix"; fi
    target="./$name"
    if matches "$target"; then
        printf 'Reused\t%s\n' "$name"
        exit 0
    fi
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        if [ -z "$part" ]; then
            part=$(mktemp .nice-export-XXXXXX)
            if [ -z "$package" ]; then cat "$source" > "$part"; else run-as "$package" cat "$source" > "$part"; fi
            matches "$part" || { echo "Export verification failed for $source" >&2; exit 1; }
        fi
        # noclobber reserves a new name exclusively, including against another concurrent export.
        # Rename the already verified file on the same volume, so readers never see partial bytes.
        if (set -C; : > "$target") 2>/dev/null; then
            reserved=$target
            identity=$(stat -c '%d:%i:%s' "$reserved")
            case "$identity" in *:0) ;; *) reserved=''; echo "Destination changed: $name" >&2; exit 1 ;; esac
            if ! mv -fT "$part" "$target"; then
                echo "Could not publish $name; the original video is intact." >&2
                exit 1
            fi
            part=''
            reserved=''
            printf 'Copied\t%s\n' "$name"
            exit 0
        fi
        # Another writer may have filled this slot while the movie was copying.
        if matches "$target"; then printf 'Reused\t%s\n' "$name"; exit 0; fi
        [ -e "$target" ] || [ -L "$target" ] || { echo "Cannot create $name" >&2; exit 1; }
    fi
    index=$((index + 1))
done
"""


def export_downloads(device):
    device.check_installation(restoring=False)
    path = device.pref("video_library.xml")
    require(path, "No download catalog found in this installation. Keep the old app installed.")
    data = device.app("cat " + path, stdout=subprocess.PIPE).stdout
    require(len(data) < 32 * 1024 * 1024, "Unexpectedly large preferences file.")
    root = ET.fromstring(data)
    require(root.tag == "map", "Invalid download catalog.")
    ready = []
    unfinished = 0
    for node in root:
        key = node.get("name", "")
        if key.startswith("movie."):
            movie = json.loads(node.text)
            disk = movie.get("disk")
            if not disk:
                continue  # Files opened with Android's document picker already live outside the app.
            require(key == "movie." + movie["id"] and re.fullmatch(UUID, movie["id"])
                    and MOVIE.fullmatch(disk) and not movie.get("publicDownload"),
                    "Unexpected entry in the old download catalog.")
            if movie.get("state", "ready") == "ready":
                ready.append(movie)
            else:
                unfinished += 1
    if unfinished:
        print(f"Skipped {unfinished} unfinished or failed download(s).")
    if not ready:
        print("No completed downloads to export.")
        return
    require(device.select_movies_access(restoring=False),
            "USB debugging cannot read the old Movies directory on this device. Keep the old app installed.")
    copied = reused = 0
    for index, movie in enumerate(ready, 1):
        source = MOVIES + "/" + movie["disk"]
        stem, suffix = export_title(movie.get("name") or movie["disk"], movie["disk"])
        print(f"[{index}/{len(ready)}] {stem}{suffix}", flush=True)
        item = device.digest(source)
        require(item and item["bytes"] > 0 and
                (movie.get("bytes", -1) < 0 or item["bytes"] == movie["bytes"]),
                f"Completed video missing or incomplete: {source}. Previous exports and originals are preserved.")
        args = [PUBLIC, stem, suffix, source, str(item["bytes"]), item["sha256"],
                "" if device.external == device.run else PACKAGE]
        command = "sh -c " + shlex.quote(EXPORT_COPY) + " nice-export " + " ".join(map(shlex.quote, args))
        result = device.run(command, stdout=subprocess.PIPE).stdout.decode().rstrip("\n")
        outcome, filename = result.split("\t", 1)
        require(outcome in ("Copied", "Reused"), "Unexpected export result.")
        copied += int(outcome == "Copied")
        reused += int(outcome == "Reused")
        print(f"  {outcome}: {PUBLIC}/{filename}", flush=True)
    print(f"Verified export complete: {copied} copied, {reused} already present. {PUBLIC}/")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("backup", "restore", "export"))
    parser.add_argument("directory", nargs="?", type=Path, help="Computer backup directory for backup and restore")
    parser.add_argument("--serial", help="ADB device serial if multiple devices are connected")
    args = parser.parse_args()
    if (args.mode == "export") != (args.directory is None):
        parser.error("Use export with no directory; backup and restore require a computer directory.")
    os.umask(0o077)
    try:
        device = Device(args.serial)
        if args.mode == "export":
            export_downloads(device)
        else:
            (backup if args.mode == "backup" else restore)(device, args.directory.expanduser())
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError, KeyError, TypeError) as error:
        sys.exit(f"Stopped: {error}")


if __name__ == "__main__":
    main()
