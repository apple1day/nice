# 签名到期倒计时与提醒

基于 `v1.2_batch_delete` 的 `8735fe1a05ef03773f3003768986f3f6539f8d90`。

## 在手机上查看

在仓库根目录运行 `bash ios/repair-project.sh`，重新生成工程并打开
`NiceVideos.xcworkspace`。保持原有 Team / Bundle Identifier，在 Xcode 中选择
原来的 iPhone，Run 覆盖安装。不要先卸载 App。此功能不修改视频文件和下载索引。

设置顶部新增“签名有效期”：剩余天/小时、到期时间、时区、到期提醒开关、重新检查。
不足 48 小时，在“本地”页顶部出现橙色提示；不足 24 小时为红色，显示小时/分钟。
点击提示可查看完整信息。播放器不增加遮挡提示，也不执行签名检查。

Debug 构建可进入“设置 → 签名有效期 → 查看提醒样式（演示）”，立即查看正常、
临近到期、不足一天、已过期、无法读取五种样式。演示页有明确标识，不改变真实状态、
不写入偏好、不安排通知。Release 不包含演示入口。

## 到期提醒

默认关闭，只有主动打开开关才申请通知权限。已授权时安排到期前 48 小时和 24 小时
两条本地通知；已错过的时间不补发，不在到期之后提醒。不连接视频服务器、不要求后台常驻。
不足 24 小时才开启时可能没有可安排的通知，此时请直接依据倒计时刷新签名。

权限被拒绝会显示说明及系统设置入口，静默授权也会标注；通知最终展示由 iOS 的授权、
专注模式等设置决定。此功能不会替 App 续签。

新安装版本第一次启动会重读实际描述文件。前台激活时刷新权限及通知安排；关闭开关、
到期时间变化、读不到描述文件时清理本功能的旧通知，不影响其他功能的通知。
异步安排使用串行队列，避免先前开启的异步任务在关闭之后重新添加通知。

## 数据来源与边界

仅解析当前 App bundle 的 `embedded.mobileprovision` 中 CMS eContent 内的 plist，
提取 `ExpirationDate`。不按安装时间加七天，不猜测账号类型。不验证证书链、证书撤销、
CMS 密码学签名或 iOS 启动策略，因此只作为到期提醒而不是可运行时间保证。
未来描述文件格式发生变化时显示未知，不阻止本地播放。

使用有大小、深度、节点数量限制的 BER/DER 解析器，支持 XML/binary plist 和 constructed
OCTET STRING；不通过全文件搜索 XML 文本猜测日期。不调用私有 API 或 macOS 专属 CMS API。
不打印、上传或持久化原始描述文件，不添加真实签名凭据到仓库。

模拟器显示“无法确定”，因为没有设备描述文件；App Store 等安装方式缺失该文件时也不
显示“永久有效”。手机时间影响倒计时，请保持系统时间正确。UTC 绝对通知日期避免跨时区漂移。

首次读取在 utility task 中运行，仅访问这个小文件。之后各签名视图每分钟更新自己的文字，
不会发布全局逐秒时钟、订阅下载进度、触发 VideoStore 文件核对或扫描 Media 目录。
手动“重新检查”可重读描述文件，但不会延长描述文件本身的有效期。

## 测试与工程接入

`project.yml` 已按目录包含 `NiceVideos/` 和 `Tests/`，无需手工维护生成的 pbxproj；新增
Swift 文件后必须重新运行 setup/repair，以更新 Compile Sources。

```bash
# Foundation 解析和通知调度测试：Linux/macOS，无需 iOS SDK 或网络依赖。
bash ios/check-signing.sh

# 完整模拟器构建与 XCTest（含真实 VLC 相关测试）：Mac + Xcode。
bash ios/test.sh
```

已在 Linux Swift 6.2.1 环境（Swift 5.9 package language mode）执行 17 项 XCTest，全部通过。
全部新增/修改 Swift 文件也通过语法解析；此检查不是 iOS SDK 类型检查。
创建此改动的环境没有 Xcode/iOS SDK，未执行完整 App 构建、真实签名解析和真机通知展示。
现有 macOS CI 将自动包含新增 XCTest，并增加独立 `check-signing.sh` 步骤。

真机验收还需检查：真实到期时间与 Xcode 描述文件一致；通知授权开/关；覆盖安装保留视频；
飞行模式查看签名；修改系统通知权限后返回 App；横竖屏和大字体；旧提醒更新。
通知展示不得以单元测试通过替代真机验收。

## 参考

- Apple TN3125 — Inside Code Signing: Provisioning Profiles
  https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- Apple UserNotifications / UNCalendarNotificationTrigger
  https://developer.apple.com/documentation/usernotifications/uncalendarnotificationtrigger
