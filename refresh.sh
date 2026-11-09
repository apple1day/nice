#!/usr/bin/env bash
# Usage: bash refresh.sh
# Move only NiceVideos provisioning profiles out of Xcode's local caches.
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
  echo "此脚本仅适用于 macOS，请在安装 Xcode 的 Mac 上运行。" >&2
  exit 1
fi

if pgrep -x Xcode >/dev/null; then
  echo "请先按 Command + Q 完全退出 Xcode，再运行。" >&2
  exit 1
fi

# Keep in sync with ios/project.yml; includes .tests, .uitests and their runners.
bundle="com.anxiong.nicevideos"
backup=""
count=0
skipped=0
umask 077
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for dir in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$dir" ] || continue

  for file in "$dir"/*.mobileprovision; do
    [ -f "$file" ] || continue

    if ! security cms -D -i "$file" >"$tmp" 2>/dev/null; then
      skipped=$((skipped + 1))
      continue
    fi
    if ! app_id=$(/usr/libexec/PlistBuddy \
      -c 'Print :Entitlements:application-identifier' "$tmp" 2>/dev/null); then
      skipped=$((skipped + 1))
      continue
    fi

    # Match an explicit app ID or its dot-separated children, never shared IDs
    # such as TEAM.* or TEAM.com.anxiong.*.
    case "${app_id#*.}" in
      *'*'*) continue ;;
      "$bundle"|"$bundle".*)
        expiry=$(/usr/libexec/PlistBuddy \
          -c 'Print :ExpirationDate' "$tmp" 2>/dev/null || printf '未知')

        if [ -z "$backup" ]; then
          mkdir -p "$HOME/Desktop"
          backup="$(mktemp -d "$HOME/Desktop/NiceVideos-Profiles-$(date +%Y%m%d-%H%M%S)-$$-XXXXXX")"
          printf '本次备份位置：%s\n\n' "$backup"
        fi

        next=$((count + 1))
        destination="$backup/$next"
        mkdir "$destination"
        printf '%s\n' "$file" >"$destination/original-path.txt"
        if ! mv "$file" "$destination/"; then
          printf '移走失败：%s\n已完成 %s 份，备份保留在：%s\n' \
            "$file" "$count" "$backup" >&2
          exit 1
        fi
        count="$next"
        printf '已移走：%s\n旧到期时间：%s\n备份文件：%s/%s\n\n' \
          "$app_id" "$expiry" "$destination" "${file##*/}"
        ;;
    esac
  done
done

printf '共移走 %s 份 NiceVideos 描述文件。\n' "$count"
if [ "$count" -gt 0 ]; then
  printf '备份位置：%s\n' "$backup"
else
  printf '没有找到明确匹配 %s 的描述文件；未移走任何描述文件。\n' "$bundle"
fi
if [ "$skipped" -gt 0 ]; then
  printf '另有 %s 份描述文件无法解码或缺少 App ID，已跳过。\n' "$skipped"
fi

cat <<'NEXT'

接下来：
1. 打开仓库中的 ios/NiceVideos.xcworkspace。
2. 在 NiceVideos -> Signing & Capabilities 中选择自己的 Team，
   并开启 Automatically manage signing。
3. 连接 iPhone，选择真机作为运行设备，重新 Build / Run。
   如果 workspace 尚未生成，先在仓库根目录运行：bash ios/repair-project.sh

本脚本只重置本地描述文件缓存。Xcode 需联网重新获取/生成描述文件并签名安装；
新的签名到期时间以实际安装的 App 为准。
NEXT
