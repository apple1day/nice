# Nice 视频 · Android

[下载 NiceVideos.apk](./NiceVideos.apk)

Android 8.0（API 26）及以上的手机和平板可以安装本目录的测试版 APK。它使用 Android 自带的媒体解码器和 OpenGL ES 2.0。安装 APK 或用 Android Studio 打开本目录均可，无需运行 iOS 工程。

## 安装试用

将 `NiceVideos.apk` 传到设备，在系统文件管理器中点开安装。如果系统询问是否允许本次来源安装应用，可给打开 APK 的文件管理器授权。已连接 USB 调试的 Mac 也可在仓库根目录执行：

```sh
adb install -r android/NiceVideos.apk
```

这是用于侧载试用的 debug 签名包。覆盖更新需要使用相同的签名证书。

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
./gradlew :app:assembleDebug
```

输出为 `app/build/outputs/apk/debug/app-debug.apk`。运行设备测试另需 FFmpeg、Python 3 和一台 Android 设备或模拟器。测试资源由 Gradle 生成，只放入测试包。

```sh
./gradlew :app:connectedDebugAndroidTest
```
