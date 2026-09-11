# 编译报错：Cannot find ... in scope

## 本次报错对应的文件

| 找不到的名称 | 定义所在文件 |
|---|---|
| OfflineMediaPolicy、PlaybackPosition | NiceVideos/OfflineMediaPolicy.swift |
| PlaybackPhase、PlaybackSnapshot、LocalPlaybackEngine、VLCPlaybackEngine | NiceVideos/VLCPlaybackEngine.swift |

这些类型在同一个 App target 中，不需要添加 Swift import，也不应补空类型绕过报错。
当新增文件没有进入 target 的 Compile Sources 时，会连带出现 `.playing`、`.paused`、闭包参数推断等大量错误。

本仓库的 `.xcodeproj`、`.xcworkspace` 是生成文件并且被 Git 忽略。`git pull` 更新 Swift 源码，
不会更新之前生成的工程。这与“CI 全新生成工程能编译，但本地旧工程找不到新增类型”的症状一致。
另一种可能是源码未完整拉取，修复脚本会区分并提示。

## 一次性修复（Mac）

先保存代码并关闭 NiceVideos 的 Xcode 窗口，然后在仓库根目录执行：

```bash
git fetch origin
git switch codex/ios-native-offline-video
git pull --ff-only origin codex/ios-native-offline-video
brew install xcodegen cocoapods
bash ios/repair-project.sh
```

脚本会先备份已有工程和工作区到 `ios/.project-backups/`，提取每个构建配置的原 Bundle ID、
Team、签名方式、签名身份、profile 和 entitlements，再生成包含全部 Swift 文件的新工程、
安装锁定版本的 CocoaPods 依赖，并检查实际 Compile Sources 和工作区引用。最后打开 `.xcworkspace`。
它不会清理 Git 改动、删视频、卸载 App 或读取私钥。无法解析旧工程时会停止，避免盲目覆盖。
生成文件中其他手工改过的构建设置需保存在 `project.yml` 中；备份保留了旧工程以便查阅恢复。
新旧签名需要有意变更时请在生成后的 Xcode 中修改，下一次 setup 会保留新值。

运行脚本后，Xcode 选择 `NiceVideos` scheme，执行 Product → Clean Build Folder，然后重新 Build/Run。
确认打开的是 `ios/NiceVideos.xcworkspace`；不要打开相邻的 `.xcodeproj`。
不要卸载手机上的旧 App：保持原 Bundle ID/签名覆盖安装，避免丢失已下载视频。

## 只检查，不修改

```bash
python3 ios/tools/project_doctor.py check
```

检查器读取实际 `PBXSourcesBuildPhase`，不是搜索文件名是否出现在工程注释中。
它也检查测试 target，避免误把“文件只在测试 target 中”视为 App 可编译。
新的工程增加了构建前源码成员检查，以后添加 Swift 文件却没有重生成工程时会直接提示重新运行修复脚本。
这个检查不会自动修改一个正在编译的工程。

## 手动核对

在 Xcode 的 Project navigator 找到上表两个 Swift 文件，File inspector → Target Membership 应勾选 `NiceVideos`。
Target → Build Phases → Compile Sources 中也应有这两个文件。
仅勾选 `NiceVideosTests` 不够；仅在 Finder 中存在、或仅有工程引用也不够。
如果改为提示 `No such module MobileVLCKit`，检查 CocoaPods 安装结果和 `.xcworkspace`，不要删掉 `import MobileVLCKit`。

## 回归验证

```bash
python3 -m unittest discover -s ios/tools -p test_project_doctor.py -v
bash ios/test.sh
xcodebuild -quiet -workspace ios/NiceVideos.xcworkspace -scheme NiceVideos \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath ios/DerivedData-device CODE_SIGNING_ALLOWED=NO build
```

工程检查器有 11 个跨平台测试，另有 1 个 macOS/XcodeGen 集成测试：先生成遗漏两个新文件的旧工程，
确认能检测到遗漏，再重生成工程，验证全部文件进入编译且 Debug/Release 的自定义 Bundle ID/Team 保留。
CI 还执行模拟器播放器测试和不签名的 iPhone SDK Release 编译。设备 SDK 编译不等于真机播放或签名已通过。
