# NiceVideos 15

独立 iOS 15.0+ 精简工程，不影响 ios/ 原工程。默认服务器 http://192.168.168.2:8106，可修改。
使用现有 GET /api/videos 和 downloadUrl。下载为前台单任务，校验 HTTP 状态及文件大小。
下载保存于 Documents/Downloads，支持 Files 文件共享；一键删除只删除该目录的本地文件，不请求服务器删除接口。普通播放使用 AVKit，仅支持系统可解码格式；不提供 VR、VLC 或后台下载。
独立 Bundle ID com.anxiong.nicevideos15，与原版可同时安装，不共享下载。

## 构建
在 Mac 安装 Xcode 和 XcodeGen（brew install xcodegen），执行：
```sh
cd ios15
xcodegen generate
open NiceVideos15.xcodeproj
```
在 Signing & Capabilities 选择自己的 Team，连接 iOS 15.8.4 真机并 Run。
