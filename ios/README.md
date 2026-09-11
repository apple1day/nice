# Nice 视频：原生 iOS 离线客户端

这是 `videos/` Go 服务的 SwiftUI + AVPlayer 客户端，不是 WebView，不需要 Jellyfin、Node、数据库或第三方播放器运行时。

**交付状态：第一版实现，需通过 macOS/Xcode 编译及真机验收后再合并。生成代码的环境没有 Xcode，不能把源码提交等同于已通过真机测试。** PR 配有 macOS CI，实际结果以 Actions 为准。

## 快速运行

要求：Mac、Xcode 15 或更高版本、iOS 17+。只需安装一次构建工具 XcodeGen（它不进入 App）：

```bash
brew install xcodegen
cd ios
xcodegen generate
open NiceVideos.xcodeproj
```

在 Xcode 选择 `NiceVideos` target → Signing & Capabilities → 选择自己的 Team。Bundle Identifier 默认 `com.anxiong.nicevideos`，有冲突时改成自己的唯一标识。本工程没有 Widget extension。

选择 iPhone 真机后运行；首次访问局域网需要授权。在「设置」填 `http://你的Mac局域网IP:8106`。**真机不能填 localhost/127.0.0.1，那指的是手机自己。** 服务器根路径部署，暂不支持反向代理路径前缀。公网应使用 HTTPS。

后端在仓库根目录启动：

```bash
cd videos
VIDEO_DIR="/Users/even/mine/some" PORT=8106 go run .
```

Mac 和 iPhone 处于相互可达的局域网，允许 Go 进程通过防火墙。先在手机 Safari 打开 `http://Mac的IP:8106/api/videos` 排除网络问题。代码默认端口是 8106；旧 `videos/README.md` 的 8080 表格和 ollama 目录名已过时。

## 已实现的行为

- 原生视频列表、搜索、刷新、按服务器保存列表缓存。
- 使用 `/api/stream/{name}` 在线播放；有本地副本时优先播放真实 `file://` 文件。
- 使用 `/api/download/{name}` 单独下载；“全部下载”创建独立后台任务，跳过已完成/进行中的任务，不下载 ZIP。
- 系统后台 URLSession、任务恢复、进度、取消、失败后重新下载；默认禁用新下载的蜂窝数据，可在设置开启。
- 独立“本地”页面，不要求先请求服务器、检查登录或联网成功；服务器关闭/删除文件后，本地副本仍能使用。
- 下载索引原子写入；文件保存于 Application Support/Media，排除备份，不使用可被系统清理的缓存目录。
- 下载完成校验 HTTP 状态、非错误文本/清单响应、实际文件大小，再移动到持久目录；不是把错误页面保存成 MP4。
- 中文、空格、加号、百分号等使用后端已有编码，避免重复编码；跨服务器同名文件隔离。
- 播放进度每 5 秒及关闭时保存；本地删除仅删除手机副本，不调用服务器 DELETE API。
- 原生播放器控制、横竖屏和画中画能力；具体设备行为需要真机验证。

## 明确限制

1. 当前离线下载支持 MP4、M4V、MOV **容器**；里面的音视频编码仍须 AVPlayer/设备支持。推荐先用常见 H.264 + AAC MP4 验收。MKV、AVI、WMV、FLV、WebM 等本版不下载、不承诺播放；需要时单独评估 VLCKit/其他解码器，不能仅按扩展名假定可播。
2. HLS `.m3u8` 仅尝试在线播放，不支持离线下载。HLS 的正确离线实现是 AVAssetDownloadURLSession 并保存所有资源，不是下载一个清单。现有 Go 服务按 URL 的文件名查文件，带相对子路径的 HLS 清单也可能无法在线正常工作。
3. 取消、失败重试从头下载；本版没有实现 resumeData 持久化/断点续传。正常系统挂起时后台任务交给 iOS；用户上划强退会取消后台传输，重新启动后可重试。不能承诺强退后仍然下载。
4. `httpMaximumConnectionsPerHost = 2` 是连接设置，不保证 HTTP/2 下严格只有两个下载。下载调度由系统控制，不实现只依赖前台进程运行的串行队列。
5. 文件大小检查不是密码学内容校验。后端没有 stable ID、mtime/version、SHA256。现用“服务器 + 文件名 + 文件大小”建立本地 ID；同名同大小替换无法自动检测。后续建议后端提供 ID/version/hash。
6. 尚未实现字幕下载、封面生成、存储配额/预留空间检查、自动重试退避、批量删除、Android、远程登录/鉴权和 App Store 发布素材。
7. 后端当前没有鉴权，且上传/删除接口可直接访问；仅用于可信局域网。客户端不会修复后端的公网安全问题。

## 文件与 API

| 文件 | 职责 |
|---|---|
| `NiceVideos/Core.swift` | API 模型、URL 解析、本地索引、文件验证/存储 |
| `NiceVideos/VideoStore.swift` | 列表缓存、后台任务、恢复、下载/播放状态 |
| `NiceVideos/Views.swift` | 视频/本地/下载/设置四个页面 |
| `NiceVideos/PlaybackScreen.swift` | 原生播放与进度保存 |
| `NiceVideos/NiceVideosApp.swift` | App 入口、系统后台回调 |
| `Tests/CoreTests.swift` | URL、API、文件完整性、离线索引等单元测试 |
| `project.yml` | 可重复生成 Xcode 工程的配置 |

列表响应必须是 `{"videos":[...]}`，不是裸数组；字段使用 `name/size/contentType/url/downloadUrl`。后端 `downloaded` 只表示服务器的下载历史，**客户端故意不把它映射成本机已下载**。本版不需要修改后端 API。

## 自动化测试

```bash
bash ios/test.sh  # 在仓库根目录执行
# 或指定已经安装的模拟器 UUID
DEVICE_ID="你的模拟器UUID" bash ios/test.sh
```

测试覆盖实际 API envelope、空列表、URL 规范化、拒绝非根地址/凭据地址、特殊文件名、拒绝异源 endpoint、服务器隔离、格式策略、HTTP/HTML/HLS/截断文件拒绝、本地索引重载、缺失文件、损坏索引保留、重试 attempt 隔离。

这些测试不是后台下载端到端测试，也不能证明所有设备/编码都能播放。合并前必须进行以下验收：

| 场景 | 预期 |
|---|---|
| 真机第一次连接 Mac API | 请求局域网权限，显示列表 |
| 下载一个 H.264/AAC MP4 | 进度完成，本地页面出现记录 |
| 飞行模式，关闭 Wi-Fi，再强退/重启 App | 不依赖服务器，可进入本地页播放和拖动 |
| 下载后关闭 Go 服务、删除服务器原视频 | 本地副本仍能播放 |
| 服务器历史显示 downloaded=true，但手机未下载 | 不得显示“已在本机” |
| 大文件下载时锁屏、正常切后台 | 观察系统调度与完成后的索引落盘 |
| 下载途中手动上划强退 | 重新启动后可以识别中断并重试，不伪装完成 |
| 同时取消、立即重试 | 旧任务回调不能覆盖新 attempt 的状态 |
| 手机存储不足/404/HTML错误页/文件被替换 | 明确失败，不出现在本地可播放列表 |
| 切换另一服务器，同名视频 | 下载隔离，原本地副本仍在 |
| 手机删除本地副本 | 服务器原文件不受影响 |

## 后端下一步建议（本次未修改）

优先增加稳定 ID、修改时间/版本、校验值和鉴权；文件上传改为临时文件完成后原子重命名，避免播放器/下载器读取半成品。`downloaded` 应改名为更准确的历史指标，或由客户端完成后回报记录，但本机离线状态永远由本机维护。还应检查 symlink 路径逃逸、上传体积限制、覆盖同名文件、HEAD 请求误记下载等问题。

参考：
- Apple background downloads: https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- Apple force-quit limitation: https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)
- Apple ATS/local networking: https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- VLC iOS: https://github.com/videolan/vlc-ios
