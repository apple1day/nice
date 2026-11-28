# nice
# 2026-9-18
给我增加视频的收藏功能，收藏按钮可以放到删除按钮的旁边，视频收藏了以后在列表显示已收藏图标

## Mac / Xcode 一键启动

在 nice 仓库根目录执行。需要安装 Xcode；iOS 15 还需安装 XcodeGen（brew install xcodegen）。

### 最新版 iOS（含 VR）

```bash
git switch main &&
git pull --ff-only origin main &&
bash ios/setup.sh &&
open ios/NiceVideos.xcworkspace
```

### iOS 15 兼容版（不含 VR）

```bash
git switch main &&
git pull --ff-only origin main &&
(cd ios15 && xcodegen generate && open NiceVideos15.xcodeproj)
```

### 创建一键启动脚本

最新版 iOS：

```bash
cat > start-ios.command <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
git switch main
git pull --ff-only origin main
bash ios/setup.sh
open ios/NiceVideos.xcworkspace
EOF
chmod +x start-ios.command
```

iOS 15 兼容版：

```bash
cat > start-ios15.command <<'EOF'
#!/bin/bash
set -e
cd "$(dirname "$0")"
git switch main
git pull --ff-only origin main
cd ios15
xcodegen generate
open NiceVideos15.xcodeproj
EOF
chmod +x start-ios15.command
```

以后双击对应的 .command 文件，或在终端执行 ./start-ios.command / ./start-ios15.command 即可。首次真机运行在 Signing & Capabilities 中选择自己的 Team。脚本不会强制覆盖本地代码；如果 Git 提示冲突，请先处理。
