#!/usr/bin/env python3
"""通过 USB 把手机上 Nice 视频 1.0（83 KB 原版）的已下载影片复制到公共下载目录。

Mac 需要 Python 3 和 Android SDK Platform Tools。用数据线连接手机，开启 USB 调试并
在手机上允许此电脑调试，然后执行 python3 export_classic.py。
"""
import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET


PACKAGE = "com.anxiong.nicevideos"
MOVIES = "/sdcard/Android/data/" + PACKAGE + "/files/Movies"
PUBLIC = "/sdcard/Download/NiceVideos"
UUID = r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"
DISK_NAME = re.compile(UUID + r"\.[a-z0-9]{1,10}")


def shell(adb, command, check=True):
    result = subprocess.run(adb + ["shell", "-T", command], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if check and result.returncode:
        detail = result.stderr.decode(errors="replace").strip() or "设备命令失败"
        raise RuntimeError(detail)
    return result


def catalog(adb):
    # Read the committed SharedPreferences generation in a single app-UID shell.
    command = ('p=shared_prefs/video_library.xml; if [ -f "$p.bak" ]; then cat "$p.bak"; '
               'elif [ -f "$p" ]; then cat "$p"; else echo "<map/>"; fi')
    data = shell(adb, "run-as " + PACKAGE + " sh -c " + shlex.quote(command)).stdout
    if len(data) > 32 * 1024 * 1024:
        raise ValueError("片库记录过大，已停止。")
    root = ET.fromstring(data)
    if root.tag != "map":
        raise ValueError("未能读取原版 App 的片库。")
    ready, unfinished = [], 0
    for node in root:
        key = node.get("name", "")
        if not key.startswith("movie."):
            continue
        movie = json.loads(node.text)
        disk = movie.get("disk")
        if not disk:
            continue  # Android document-picker entries already point to user-selected files.
        if (not DISK_NAME.fullmatch(disk) or key != "movie." + movie["id"]
                or not re.fullmatch(UUID, movie["id"]) or movie.get("publicDownload")):
            raise ValueError("发现无法识别的下载记录，已停止。")
        if movie.get("state", "ready") == "ready":
            ready.append(movie)
        else:
            unfinished += 1
    return ready, unfinished


def source_info(adb, source):
    # On different Android devices either the USB shell or the app identity can read Movies.
    probe = 'set -e; test ! -L "$1"; test -f "$1"; stat -c %s "$1"; sha256sum < "$1"'
    for identity in ("", PACKAGE):
        prefix = ("run-as " + identity + " ") if identity else ""
        result = shell(adb, prefix + "sh -c " + shlex.quote(probe) + " nice-read " + shlex.quote(source),
                       check=False)
        if result.returncode:
            continue
        fields = result.stdout.split()
        if len(fields) >= 2 and fields[0].isdigit() and re.fullmatch(b"[0-9a-f]{64}", fields[1]):
            return int(fields[0]), fields[1].decode(), identity
    raise RuntimeError("无法读取原版 App 中的这部影片，请保留旧 App 和原文件。")


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


def export(adb):
    try:
        shell(adb, "true")
    except RuntimeError as exc:
        raise RuntimeError("请用数据线连接手机并授权 USB 调试。用 adb devices 查看状态；"
                           "连接多台设备时请加 --serial 设备编号。\n" + str(exc)) from exc
    if shell(adb, "am get-current-user").stdout.strip() != b"0":
        raise RuntimeError("请切换到安装原版 App 的 Android 主用户（用户 0）。")
    info = shell(adb, "dumpsys package " + PACKAGE).stdout
    if not re.search(rb"\bversionCode=1\b", info):
        raise RuntimeError("未发现 83 KB 原版 Nice 视频（" + PACKAGE + "，版本号 1）。")
    if shell(adb, "run-as " + PACKAGE + " true", check=False).returncode:
        raise RuntimeError("设备没有授权读取此调试包，请保留已安装的原版 App。")
    ready, unfinished = catalog(adb)
    if unfinished:
        print(f"跳过 {unfinished} 个未完成或失败的下载。可在原 App 中确认状态后再导出。")
    if not ready:
        print("片库中没有下载完成的影片。请在原 App 的本地列表确认下载状态。")
        return
    copied = reused = failed = 0
    for index, movie in enumerate(ready, 1):
        source = MOVIES + "/" + movie["disk"]
        stem, suffix = export_title(movie.get("name") or movie["disk"], movie["disk"])
        print(f"[{index}/{len(ready)}] {stem}{suffix}", flush=True)
        try:
            size, digest, identity = source_info(adb, source)
            expected = movie.get("bytes", -1)
            if size <= 0 or (expected >= 0 and size != expected):
                raise ValueError("原文件大小与下载记录不符。")
            args = [PUBLIC, stem, suffix, source, str(size), digest, identity]
            command = "sh -c " + shlex.quote(EXPORT_COPY) + " nice-export " + " ".join(map(shlex.quote, args))
            result = shell(adb, command).stdout.decode().rstrip("\n")
            outcome, name = result.split("\t", 1)
            if outcome not in ("Copied", "Reused"):
                raise ValueError("设备返回了无法识别的导出结果。")
        except (ValueError, RuntimeError) as exc:
            failed += 1
            print("  导出失败：" + str(exc), file=sys.stderr, flush=True)
            continue
        copied += outcome == "Copied"
        reused += outcome == "Reused"
        label = "已复制并校验" if outcome == "Copied" else "已有相同内容"
        print(f"  {label}：{PUBLIC}/{name}", flush=True)
    print(f"本机文件管理 → 内部存储 → Download → NiceVideos（{PUBLIC}/）")
    if failed:
        raise RuntimeError(f"已复制 {copied} 个，已有相同内容 {reused} 个，{failed} 个失败。可保留原 App 后重试。")
    print(f"导出完成：复制 {copied} 个，已有相同内容 {reused} 个。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", help="多台设备连接时，指定 adb devices 列出的设备编号")
    args = parser.parse_args()
    if not shutil.which("adb"):
        sys.exit("需要安装 Android SDK Platform Tools。macOS 使用 Homebrew 时可运行："
                 "brew install --cask android-platform-tools")
    adb = ["adb"] + (["-s", args.serial] if args.serial else [])
    try:
        export(adb)
    except (ValueError, RuntimeError, OSError, ET.ParseError, KeyError, TypeError) as exc:
        sys.exit("已停止：" + str(exc))


if __name__ == "__main__":
    main()
