# Nice 视频 1.0 原版 · 导出已下载影片

这个分支基于 83,397 字节的 Android 1.0.0（`com.anxiong.nicevideos`）。1.0.1 在「本地」增加「导出全部」，也可以在影片菜单点「导出到文件夹」。通过系统文件选择器选中一个公共子目录，导出完成后即可在手机文件管理器按片名找到副本。导出只复制完成的下载，保留原片、收藏和续播位置。

**[下载已签名的 Nice 视频 1.0.1 导出版](./NiceVideos-1.0.1-classic-export.apk)**。这个 APK 使用新的经典版发行签名，桌面名称仍是「Nice 视频」。手机没有安装同包名 App 时可以直接安装。已经装有仓库 83 KB 原版的用户，先按下节将影片导出到公共目录，确认副本可播放后再决定是否更换安装。卸载旧版会清除旧片库、收藏、续播位置及应用专属目录中的影片。新安装可从首页「打开文件」选取公共目录中的副本。

1.0.1 发行证书的 SHA-256 指纹为 `1f0909325b27cc8b3f5006bc3f3f40add121f7c0dbeb403ed72a482ef1c70357`。该签名的加密恢复备份已为仓库所有者单独保留，后续版本应使用同一签名。

## 已经安装了仓库发布的 83 KB 原版

**在 Mac 上双击导出**

下载 [NiceVideos-Classic-Export-Mac.zip](./tools/NiceVideos-Classic-Export-Mac.zip) 并解压。在平板开发者选项开启「USB 调试」，用数据线连上 Mac，在平板上允许这台电脑调试，然后在 Mac 上双击文件夹中的 `导出视频.command`。看到「导出完成」后，在平板「文件管理 → 内部存储 → Download → NiceVideos」找视频。需要 Python 3 和 Android SDK Platform Tools，启动时会检查这两个工具。

请保留手机上的原 App。仓库先后发布过两份同样大小的 1.0.0 APK，各自使用构建机生成的调试签名，构建流程只保存了 APK 和测试结果。更新已安装的 App 需要与手机上那份 APK 匹配的签名私钥。当前分支的 `NiceVideos.apk` 是存档的 1.0.0。`NiceVideos-1.0.1-classic-export-unsigned.apk` 是供原签名持有人签署的 1.0.1。

**只要把现有视频导出到手机公共目录**，可在 Mac 上下载 [export_classic.py](./tools/export_classic.py)，用 USB 数据线连接手机，在开发者选项开启「USB 调试」，并在手机上确认允许这台电脑调试。工具需要 Python 3 以及 Android SDK Platform Tools。使用 Homebrew 的 Mac 可用 `brew install --cask android-platform-tools` 安装后者。假设脚本保存到了 Mac 的「下载」：

```sh
adb devices
python3 "$HOME/Downloads/export_classic.py"
```

等设备状态显示为 `device` 再执行第二行。完成后打开手机「文件管理 → 内部存储 → Download → NiceVideos」。影片在手机内复制，脚本校验大小及 SHA-256。再次导出会复用相同内容，和已有文件同名但内容不同的副本会增加编号。原文件保留，因此手机要有足够的剩余空间。此命令针对 Android 主用户安装的 1.0.0 调试包。如果有多个设备，使用 `python3 "$HOME/Downloads/export_classic.py" --serial 设备编号`。如果系统限制读取，工具会报告失败的影片，请继续保留旧 App。

## 有原始签名密钥的安装

使用本地 Android SDK Build Tools 的 `apksigner` 对 1.0.1 的未签名 APK 签名。将原版 APK 与签好名的新包分别传给 `apksigner verify --print-certs`，核对输出的证书 SHA-256。签名私钥和口令可一直保存在原构建电脑上。签名相同时，在设备上直接打开已签名的 1.0.1 并选「更新」，也可执行 `adb install -r 已签名的1.0.1.apk`。如果系统提示签名不同，请保留原安装，使用上面的 USB 导出。

## 播放

- 在首页点「打开文件」，用 Android 系统文件选择器选视频。播放器直接使用提供方交给它的 URI，无需将手机或平板上已有的视频导入片库。网盘提供方可能会先下载或缓存文件。拖动进度需要提供方支持随机读取。
- 在播放器内使用播放／暂停、前进／后退 15 秒和进度条。普通模式显示完整画面。横放设备后，可选半宽 SBS 或全宽 SBS 观看左右分屏视频。每只眼被横向压缩的片源选半宽，原始比例的片源选全宽。
- 分屏共用一个解码器，解码帧直接进入 GPU 纹理。支持播放的封装、编码、分辨率和帧率由设备决定。3–5 GB 的体积本身并非读取上限。
- 本地列表可按收藏或已下载筛选。文件菜单可以收藏影片、移除最近记录或删除已下载副本。
- 服务器页可填写本仓库 `videos/` 服务的地址，例如 `http://192.168.1.20:8106`，从列表下载到本机后离线播放。连接同一 Wi-Fi 时填服务器的局域网 IP。
- VR 支持平面左右分屏。此版本未实现 VR180/360 全景投影或头部追踪。

## 自行构建

使用 JDK 17、Android SDK Platform 35 及 Build Tools 35.0.0。Gradle Wrapper 位于本目录。

```sh
cd android
./gradlew :app:assembleRelease
```

待签名产物在 `app/build/outputs/apk/release/app-release-unsigned.apk`。运行设备测试另需 FFmpeg、Python 3 和一台 Android 设备或模拟器。测试资源由 Gradle 生成，只放入测试包。

```sh
./gradlew :app:connectedDebugAndroidTest
```
