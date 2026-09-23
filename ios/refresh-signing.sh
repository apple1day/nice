#!/usr/bin/env bash
set -eu

if pgrep -x Xcode >/dev/null; then
  echo "请先按 Command + Q 完全退出 Xcode，再运行。"
  exit 1
fi

bundle="com.anxiong.nicevideos"
backup="$HOME/Desktop/NiceVideos-Profiles-$(date +%Y%m%d-%H%M%S)-$$"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
count=0

for dir in \
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$dir" ] || continue

  for file in "$dir"/*.mobileprovision; do
    [ -f "$file" ] || continue

    security cms -D -i "$file" >"$tmp" 2>/dev/null || continue

    app_id=$(/usr/libexec/PlistBuddy \
      -c 'Print :Entitlements:application-identifier' "$tmp" 2>/dev/null) || continue

    case "${app_id#*.}" in
      "$bundle"|"$bundle".*)
        expiry=$(/usr/libexec/PlistBuddy \
          -c 'Print :ExpirationDate' "$tmp" 2>/dev/null || printf '未知')

        count=$((count + 1))
        mkdir -p "$backup/$count"
        mv "$file" "$backup/$count/"

        printf '已移走：%s\n旧到期时间：%s\n\n' "$app_id" "$expiry"
        ;;
    esac
  done
done

printf '共移走 %s 份 NiceVideos 描述文件。\n' "$count"

if [ "$count" -gt 0 ]; then
  printf '备份位置：%s\n' "$backup"
  echo
  echo "接下来："
  echo "1. 打开 ios/NiceVideos.xcworkspace"
  echo "2. 选择 NiceVideos Target -> Signing & Capabilities"
  echo "3. 保持 Automatically manage signing 开启"
  echo "4. 连接 iPhone 后重新 Build / Run"
  echo
  echo "Xcode 会重新获取/生成匹配 com.anxiong.nicevideos 的描述文件。"
else
  echo "没有找到明确匹配 com.anxiong.nicevideos 的描述文件；未修改任何签名文件。"
fi
