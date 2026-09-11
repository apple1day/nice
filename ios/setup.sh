#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -s)" == Darwin ]] || { echo '需要在安装 Xcode 的 Mac 上运行。'; exit 1; }
for tool in xcodegen pod; do
  command -v "$tool" >/dev/null || { echo '请先执行 brew install xcodegen cocoapods'; exit 1; }
done
xcodebuild -version >/dev/null
xcodegen generate
pod install
# The folder reference is already in the project, so these files are bundled
# even though pod install necessarily runs after XcodeGen.
license="Pods/MobileVLCKit/COPYING.txt"
[[ -f "$license" ]] || license="$(find Pods/MobileVLCKit -iname 'copying*' -type f | head -n 1)"
[[ -n "$license" && -f "$license" ]] || { echo '依赖中缺少 COPYING，停止构建。'; exit 1; }
cp "$license" Licenses/MobileVLCKit-COPYING.txt
cp 'Pods/Target Support Files/Pods-NiceVideos/Pods-NiceVideos-acknowledgements.markdown' Licenses/Acknowledgements.txt
echo '请打开 ios/NiceVideos.xcworkspace（不要打开 .xcodeproj）。'
