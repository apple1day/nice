# Nice App 图标

使用本次对话中选定的蓝紫色「nice」logo：视频播放符号、下载箭头和 nice 字样。

## 源文件与集成

- `nice-logo.webp`：真实图标源图片，已提交到 Git；来自生成的 PNG，去掉外围展示留白后缩放到 1024 × 1024，压缩为 WebP。不是重新绘制的替代图。
- `../tools/render_app_icon.swift`：使用 macOS 自带 ImageIO 解码源图片，再输出无 Alpha 的 8 位 sRGB PNG。不安装额外图像库、不联网获取图标。
- `../NiceVideos/Assets.xcassets/AppIcon.appiconset/Contents.json`：Xcode 单尺寸 iOS 图标配置，由资源编译器派生设备所需尺寸。
- `../project.yml`：已指定 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`，构建号递增为 4。Bundle Identifier、Team 及本地视频存储逻辑未改。

PNG 由 `setup.sh` 在生成 Xcode 工程前准备；生成文件不重复提交到 Git。源文件和配置均在仓库中，拉取后不需要手动拖放图片。

当前源文件 SHA-256：`545bbf9fb3a7ab640332909212726f1729930df7b4fc04113160795304e49b85`。

## 拉取并测试

先保存并关闭 Xcode 工程窗口；在仓库根目录执行：

```bash
git fetch origin
git switch v1.2_batch_delete
git pull --ff-only origin v1.2_batch_delete
cd ios
bash setup.sh
open NiceVideos.xcworkspace
```

选择原来的 Team 和手机，Run 覆盖安装。不要卸载 App、不要更改原 Bundle Identifier，本次不需要清空本地视频。

如果桌面仍是旧图标，先确认 setup.sh 成功、当前 target 的 App Icons Source 为 AppIcon；再用 Xcode 的 Product → Clean Build Folder 重新编译覆盖安装。不要以卸载 App 作为第一步。

## 检查

```bash
# 包含源图校验、资源配置和 macOS 原生转 PNG 检查
python3 -m unittest discover -s ios/tools -p 'test_app_icon.py' -v
# 完整 App 测试，新增 AppIconTests 检查图标确实进入宿主 App 的 Info.plist
bash ios/test.sh
```

原生 PNG 转换测试需要 macOS；完整编译及宿主 App 测试需要 Xcode/iOS SDK。既有 CI 会运行这些新增测试；实际结果以对应提交的 Actions 为准。真机桌面外观需要安装后确认。

参考：Apple Configuring your app icon、Asset Catalog Format Reference（App Icon Type）。后续替换 logo 时同时更新源文件与源图校验测试中的 SHA-256。
