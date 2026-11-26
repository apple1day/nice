#!/usr/bin/env python3
"""Back up/restore Nice VR 1.2 downloads on your own USB-debugging device (Android owner profile)."""
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
                    method(f"test -d {probe} && ls -A {probe} >/dev/null",
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except subprocess.CalledProcessError:
                    continue
                self.external = method
                return
        raise ValueError("USB debugging cannot read the app's Movies directory: " + MOVIES
                         + ". Verify the Android owner profile and keep the original installation.")

    def stop(self, restoring):
        owner = self.run("am get-current-user", stdout=subprocess.PIPE).stdout.strip()
        require(owner == b"0", "Switch to the Android owner profile (user 0).")
        self.app("true")
        package_info = self.run("dumpsys package " + PACKAGE, stdout=subprocess.PIPE).stdout
        version = re.search(rb"\bversionCode=(\d+)\b", package_info)
        require(version, "Cannot determine the installed Nice app version.")
        require(int(version[1]) >= 4 if restoring else int(version[1]) == 3,
                "Backup needs the old 1.2.0 trial (code 3); restore needs the updated app (code 4 or newer).")
        self.run("am force-stop " + PACKAGE)

    def digest(self, path):
        # Paths passed here consist exclusively of locally constructed, allowlisted names.
        raw = self.text("if [ -L {0} ]; then exit 1; elif [ -f {0} ]; then "
                        "stat -c %s {0} && sha256sum {0}; elif [ -e {0} ]; then exit 1; fi".format(path), path)
        if not raw:
            return None
        lines = raw.splitlines()
        return {"bytes": int(lines[0]), "sha256": lines[1].split()[0]}

    def movies(self):
        parent = MOVIES.rsplit("/", 1)[0]
        # 'test -d' alone reports false on EACCES too. Require a readable parent
        # before accepting an absent Movies directory as empty.
        result = self.text(f"if [ -d {MOVIES} ]; then ls -A1 {MOVIES}; "
                           f"else ls -A {parent} >/dev/null; fi", MOVIES + "/")
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


def check_catalog(data, movies, restoring=False):
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
    device.select_movies_access(restoring=False)
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
    temp = (MOVIES.rsplit("/", 1)[0] if directory == MOVIES else directory) + "/.nice-restore-" + name + ".part"
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
    for name in PREFS:
        path = device.pref(name)
        if path:
            require(not path.endswith(".bak"), "Target has an interrupted preferences update. Inspect the app first.")
            current = device.digest(path)
            if name not in prefs or current != bytes_digest(prefs[name]):
                require(current["bytes"] < 4096, "Target already contains app settings.")
                xml = ET.fromstring(device.app("cat " + path, stdout=subprocess.PIPE).stdout)
                require(xml.tag == "map" and len(xml) == 0, "Target already contains library records or settings.")
    # Android 11+ provisions package-owned external directories through Context.
    # PREPARE_RESTORE creates Movies and finishes without starting downloads or migration.
    device.run("am start -W -n " + PACKAGE + "/com.anxiong.nicevideos.MainActivity "
               "-a com.anxiong.nicevideos.PREPARE_RESTORE", stdout=subprocess.DEVNULL)
    device.run("am force-stop " + PACKAGE)
    device.select_movies_access(restoring=True)
    device.app("mkdir -p shared_prefs")
    require(set(device.movies()) <= set(info["Movies"]), "Target contains other videos. Start with a fresh installation.")
    missing_bytes = 0
    for name, expected in info["Movies"].items():
        current = device.digest(MOVIES + "/" + name)
        require(current is None or current == expected, f"Different movie exists on target: {name}")
        if current is None:
            # A disconnected run can leave its partial transfer in staging. The
            # bytes will be released when cat truncates that same staging file.
            stage = MOVIES.rsplit("/", 1)[0] + "/.nice-restore-" + name + ".part"
            stage_size = int(device.text(f"if [ -f {stage} ]; then stat -c %s {stage}; else echo 0; fi", stage))
            missing_bytes += max(0, expected["bytes"] - stage_size)
    free = device.text("df -k " + MOVIES, MOVIES + "/").splitlines()[-1].split()
    require(int(free[-3]) * 1024 >= missing_bytes, "Not enough space to restore the videos.")
    for i, (name, item) in enumerate(info["Movies"].items(), 1):
        print(f"[{i}/{len(info['Movies'])}] Restore {name}", flush=True)
        upload(device, MOVIES, name, item, source=root / "Movies" / name)
    for name, data in prefs.items():
        upload(device, "shared_prefs", name, bytes_digest(data), data=data, replace_empty=True)
    print("Verified restore complete. Open the updated Nice app to migrate the historical downloads.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("backup", "restore"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("--serial", help="ADB device serial if multiple devices are connected")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        (backup if args.mode == "backup" else restore)(Device(args.serial), args.directory.expanduser())
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError, KeyError, TypeError) as error:
        sys.exit(f"Stopped: {error}")


if __name__ == "__main__":
    main()
