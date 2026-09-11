#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -s)" == Darwin ]] || { echo '需要在安装 Xcode 的 Mac 上运行。'; exit 1; }
for tool in xcodegen pod python3; do
  command -v "$tool" >/dev/null || { echo '请先安装 Xcode 命令行工具，并执行 brew install xcodegen cocoapods'; exit 1; }
done
xcodebuild -version >/dev/null
printf '%s\n' '请先保存并关闭此工程的 Xcode 窗口，避免旧窗口写回旧工程配置。'
# Git ignores generated projects: pulling new Swift files does not update target
# membership. Always regenerate, preserving locally edited signing beforehand.
spec="$(python3 -c 'import tempfile; f = tempfile.NamedTemporaryFile(dir=".", prefix=".project-setup-", suffix=".json", delete=False); print(f.name); f.close()')"
trap 'rm -f -- "$spec"' EXIT
python3 tools/project_doctor.py prepare --output "$spec"
xcodegen generate --spec "$spec"
python3 tools/project_doctor.py check --sources-only
pod install
# Folder reference exists before dependency installation, so licenses are bundled.
license="Pods/MobileVLCKit/COPYING.txt"
[[ -f "$license" ]] || license="$(find Pods/MobileVLCKit -iname 'copying*' -type f | head -n 1)"
[[ -n "$license" && -f "$license" ]] || { echo '依赖中缺少 COPYING，停止构建。'; exit 1; }
cp "$license" Licenses/MobileVLCKit-COPYING.txt
cp 'Pods/Target Support Files/Pods-NiceVideos/Pods-NiceVideos-acknowledgements.markdown' Licenses/Acknowledgements.txt
python3 tools/project_doctor.py check
printf '%s\n' '工程及依赖已更新。请打开 ios/NiceVideos.xcworkspace（不是 .xcodeproj）。' \
  '原签名设置已保留；其他自定义构建设置应写入 project.yml，旧工程备份位于 ios/.project-backups。'
