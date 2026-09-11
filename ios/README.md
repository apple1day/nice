# Nice 视频 — VLC 原生离线版

SwiftUI + **MobileVLCKit 3.7.3**，对接仓库 `videos/` 的列表和下载 API。
**不提供在线播放：先下载完整文件，再播放手机里的真实文件。** 不使用 WebView，不需要 Jellyfin。

## 在 Mac 上运行

```bash
# 在仓库根目录
brew install xcodegen cocoapods
bash ios/setup.sh
open ios/NiceVideos.xcworkspace
```

要求：Xcode 15+、iOS 17+。安装依赖需要外网；App 播放本地文件不需要外网。

**CocoaPods 接入后必须打开 `.xcworkspace`，不再使用 `.xcodeproj` 运行。**
在 `NiceVideos` target 的 Signing & Capabilities 选择自己的 Team。默认 Bundle Identifier 仍是
`com.anxiong.nicevideos`，与第一版保持一致。已安装旧版时不要卸载；保持原标识和签名更新，
旧的 Media 文件、v1 下载索引、`position.<id>` 播放位置会继续使用。
若以前改过标识或 Team，应在 `project.yml` 保留相同配置，避免重新生成工程后变回默认值。

App 默认打开「本地」。首次下载：设置 → `http://192.168.19.70:8106` → 保存并读取 → 服务器 → 下载。
地址只是用户当前局域网示例，可修改；真机不要填 localhost。允许系统首次提示的局域网权限。
后端仍然这样运行，无需改接口：

```bash
cd videos
PORT=8106 go run .
```

## 行为与边界

- 只有用户主动保存服务器或点击刷新才请求 `/api/videos`；冷启动不刷新、不检测登录或网络。
- 下载使用 API 返回的 `/api/download/...`，单个文件独立任务；批量下载不使用 ZIP。
- 不创建 `/api/stream/...` 播放请求。服务器返回的 `url` 仅为 API 兼容保留，不参与播放。
- 本地页独立于服务器设置/缓存/下载任务恢复，断网启动也能进入。
- 请求构造、下载索引和 VLC 入口分别检查本地文件；文件缺失时明确报错，绝不回退网络。
- HTTP 状态、响应类型、文件大小检查通过后同步移动到 Application Support，再原子保存索引。
  下载的错误文本和常见伪装播放清单会被拒绝。大小与头部检查不等于完整解码或密码学校验。
- VLC 提供播放/暂停、进度条、前后 15 秒；位置定期保存，关闭/暂停时保存，播完清除旧位置。
- 全屏页面支持系统横竖屏；锁屏/切后台/来电/拔出耳机时暂停，返回不自动发声。
- 重复视图更新不会重复启动；关闭时停止原生输出、解除 drawable/delegate，并丢弃晚到事件。
- 默认禁止新下载使用蜂窝数据，可在设置打开。已有任务的网络策略需取消重试后才改变。

当前允许下载 MP4/M4V/MOV/MKV/AVI/WebM/OGG/FLV/WMV/TS 完整文件；容器白名单不保证所有编码、
配置档次、码率或损坏文件可播放。HLS/DASH、M3U/PLS 等清单不支持离线下载，也不提供在线回退。
没有实现外部字幕下载/音轨字幕选择、倍速、画中画、后台音频、断点续传、空间配额。
失败/取消后重试是重新完整下载；iOS 手动上划强退会中止后台传输，不承诺强退后继续下载。

## 固定依赖与许可证

`Podfile` 指定 `MobileVLCKit = 3.7.3`，使用官方生产发行包，不跟随 4.0 开发分支。
CocoaPods 发布 spec 的 SHA256 校验值为：

```
0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9
```

`setup.sh` 安装依赖后复制实际 COPYING 和 CocoaPods acknowledgements，随 App 打包，
可在「设置 → 开源组件与许可证」离线查看。依赖解析记录见 `Podfile.lock` 和 CI artifact。

这是使用 VLC 内核的自定义界面，没有复制 VLC for iOS 应用代码。发布前仍须完成 LGPL 及底层依赖的
源码提供/重链接等适用合规要求；带上通知并不自动满足全部发布条件。此交付不是 App Store 发布包。

## 测试

```bash
# 核心离线策略测试：Mac/Linux 都可运行（需要 Swift）
bash ios/check-policy.sh

# Xcode 编译、单元测试、真实 VLC 本地解码测试：Mac
brew install ffmpeg
bash ios/test.sh
# 可指定模拟器
DEVICE_ID="模拟器UUID" bash ios/test.sh
```

测试前本地生成 3 秒的 H.264/AAC MP4 与 MPEG-4 Part 2/AAC MKV 合成样片，
无网络视频、无用户视频。样片仅进入测试包，不进入正式 App。

- `CoreTests`：API/URL 编码、服务器隔离、格式清单、HTTP/文件验证、v1 索引重载、
  拒绝远程播放地址、缺失文件/符号链接/伪装清单、无服务器配置/不可达服务器下本地播放。
- `PlaybackModelTests`：重复挂载、延迟续播、首次出画面前关闭、暂停保存、重复关闭与晚到事件、
  播完重播、非法/越界拖动。
- `VLCDecodeTests`：直接使用固定版本的真实 VLC 内核，在模拟器窗口中解码本地 MP4/MKV，
  验证 `hasVideoOut` 且播放时间前进；再次验证引擎拒绝 HTTP 地址。

这些测试不等于物理设备端到端验收，尤其不能证明所有编码、音频输出、锁屏和后台下载都正常。
源码生成环境没有 Xcode/iOS SDK；编译/测试实际状态以该提交的 macOS CI 为准。PR 保持草稿。

## 合并前真机验收

| 场景 | 必须达到的结果 |
|---|---|
| 下载真实 MP4、MKV，检查画面与声音 | 本地文件可播放，拖动进度正常 |
| 飞行模式并关闭 Wi-Fi → 强退 → 冷启动 | 立即进入本地页，可播放已下载文件 |
| 关闭 Go 服务/删除服务器原文件/清空服务器设置 | 手机原副本仍可播放 |
| 连续打开、关闭、切换视频 | 旧视频声音和播放资源不残留 |
| 播放中锁屏、来电、拔出耳机 | 暂停，返回后用户手动继续 |
| 下载中断/空间不足/同名文件变更/HTML错误页 | 明确失败，不伪装完整下载 |
| 安装前一版并下载，再覆盖安装新版 | 原下载和进度保留（不卸载，不改变 Bundle ID） |
| 删除手机副本 | 不向服务器发送删除请求 |

## 主要文件

`OfflineMediaPolicy.swift` 是无框架依赖的本地播放边界；`Core.swift` 保存原有数据协议和索引；
`VideoStore.swift` 只负责列表、下载和本地请求；`VLCPlaybackEngine.swift` 封装固定版本 VLC；
`PlaybackScreen.swift` 管理播放状态/生命周期；`Views.swift` 默认展示本地库。

服务器仍无鉴权，不要把 8106 直接暴露公网。后端没有稳定版本/hash，同名同大小替换无法自动检测。
