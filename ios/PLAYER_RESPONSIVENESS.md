# 播放器按钮响应与进度拖动修复

按钮响应修复已通过 PR #9 合入 `main`。
进度条触摸回归的补充修复位于 `codex/ios-server-management`（PR #10），
与服务器删除、地址预填和键盘收起的更新一起交付。

## 两类故障及证据

### 上一个、下一个等失效，删除仍可用

原 `PlaybackScreen.swift` 中，切换、播放/暂停、前后 15 秒、播放列表和全屏按钮
都依赖 `canNavigate = canInteract && !controls.isScrubbing`，收藏/删除仅依赖
`canInteract`。如果进度条的结束编辑事件没有送达，残留的 `isScrubbing` 会持续
禁用前一组按钮。这个状态与报告的差异一致；具体是哪一种真机触摸或系统中断
漏掉回调，仍需要现场复现确认。

另一个问题是内部标签的命中范围：删除/收藏已撑满整个按钮格，但部分其他按钮
仅有中间 44pt 的标签，外层等宽布局没有同步扩大标签的点击区。横屏时格子变宽，
用户更容易点到只会唤醒控制栏的空白。

### 所有按钮，包括右上角关闭，都没有反应

关闭按钮没有上述拖动禁用条件，因此这一现象不能只用 `isScrubbing` 解释。
切片和关闭会替换/释放旧播放模型，旧版 native 播放器的最终销毁可能落在主线程。

固定依赖 **MobileVLCKit 3.7.3** 的官方实现显示：

- `VLCMediaPlayer.stop()` 使用 `libvlc_media_player_stop_async()`，本身是异步停止请求。
- `VLCMediaPlayer.dealloc` 会调用 `libvlc_media_player_release()`，最终 native release
  会等待尚未退出的 worker。`.stopped` 事件不能证明 worker 已经全部退出。
- VLC 自己的排队回调也可能保留 Objective-C 播放器，不能仅把应用的一次释放
  放进后台队列就认为已经控制了最后销毁的线程。

官方固定版本依据：
[VLCMediaPlayer.m](https://github.com/videolan/vlckit/blob/3.7.3/Sources/VLCMediaPlayer.m)、
[异步停止补丁](https://github.com/videolan/vlckit/blob/3.7.3/libvlc/patches/0024-lib-media_player-add-stop-set_media-async-support.patch)。

这是已确认的代码风险。没有目标 iPhone 的卡死线程堆栈，不能认定所有强退现场
都由同一处引起，也不能用单元测试代替真实长时间播放验收。

## 修复行为

1. 进度拖动有独立会话 token。取消会立即使 token 和草稿失效，迟到的结束/数值
   事件不会再次提交旧进度或覆盖下一条视频。
2. 使用独立 `UIControl` 直接处理触摸坐标，整条 44pt 高的进度区域都能起拖；
   不依赖 `UISlider` 内部的滑块命中和事件顺序。保持取消、禁用及视图移除保护，
   保留 VoiceOver 调整进度。草稿仍由进度子视图管理，拖动不扫描媒体库。
3. 切换、跳转、暂停、全屏和打开播放列表前同步取消当前拖动；这些离散按钮
   不再被一个残留的拖动布尔值永久禁用。
4. 所有传输按钮的内部标签填满各自格子；关闭按钮也在按住时阻止自动隐藏。
5. native 播放资源使用独立的后台回收路径，让底层线程退出的等待离开 UI 线程。
   旧引擎停止后拒绝晚到事件、重复挂载和重新启动。

播放器里的「删除」仍然只标记待删除；实际删除由本地列表中的确认操作执行。
本次保留已有播放请求、位置保存、播放顺序和停止请求提交后的文件保护语义，
没有把文件保护改成“等待所有解码线程退出后才解除”的新异步协议。

## 进度条触摸回归

原进度条测试直接调用拖动会话入口，没有覆盖系统真实触摸派发和 SwiftUI 中的
命中范围，因此不能证明手指能够拖动。补充修复明确了进度条的全宽布局与 44pt
触摸高度，从按下到松手直接映射坐标；播放时间刷新不覆盖正在拖动的草稿，
松手只提交一次跳转，取消后的迟到事件不生效。

新增 UI 测试通过实际屏幕坐标按住、拖动和松手，覆盖播放中正反拖动、暂停后拖动、
全屏、横屏及切换到下一个视频后的拖动。测试使用生产播放器界面，只有播放引擎
替换为确定性的测试引擎，并验证跳转调用和界面时间不会回弹。测试入口仅在 Debug
构建加 `--ui-test-playback` 参数时启用，使用独立临时文件和设置；Release 不包含
该入口。真实 VLC 解码仍由现有播放测试覆盖，目标 iPhone 的实际触感仍需真机验收。

## 本机更新

保存并关闭 Xcode 工程窗口，在本机 `nice` / `git_nice` 仓库根目录运行：

```bash
git fetch origin &&
git switch codex/ios-server-management &&
git pull --ff-only origin codex/ios-server-management &&
bash ios/repair-project.sh &&
open ios/NiceVideos.xcworkspace
```

新增源文件需要重新生成工程。保留原来的 Bundle Identifier 和 Team，通过 Xcode
覆盖安装，这样继续使用已有的下载文件和播放进度。

## 回归验证

```bash
# Mac，或安装 Swift 的 Linux：纯状态与资源回收测试
bash ios/check-player-controls.sh
bash ios/check-player-teardown.sh
bash ios/check-playlist.sh

# 工程与接线检查
python3 -m unittest discover -s ios/tools -p 'test_*.py'

# Mac + Xcode：完整 App、UIKit、真实触摸 UI 测试、播放模型与真实 VLC 解码
bash ios/test.sh
```

CI 还执行无签名 iPhone SDK Release 编译。完整构建和真机结果以对应提交的
实际运行记录为准；Linux 的 Swift 语法解析和纯状态测试不包含 UIKit/SwiftUI 链接。

真机重点验证：

| 操作 | 预期 |
|---|---|
| 拖动进度时旋转、切全屏、进入后台再回来 | 可再次拖动，切换/暂停/关闭继续响应 |
| 拖动后马上点前后 15 秒或上下片，再松开旧触摸 | 旧进度不会覆盖新操作 |
| 横竖屏分别点每个图标以及格子内的空白 | 同一个按钮的命中结果一致 |
| 控制栏即将隐藏时按住按钮或关闭，再松开 | 按住期间不消失，动作只执行一次 |
| 连续切片、打开后立刻关闭、出第一帧后关闭 | 返回能执行，旧视频不重新启动 |
| 标记待删除并切到另一条，再返回本地列表 | 标记对应正确视频，确认前文件仍存在 |
| VoiceOver 调整进度、切片及关闭 | 可完成操作，每次调整只提交一次 |

若真机仍出现全界面卡住，在 Xcode 中暂停进程并查看主线程堆栈，区分底层解码
等待、音频会话调用和 UI 状态。保留当时是否正在拖动/切片/旋转及视频格式，
用于进一步定位尚未覆盖的路径。
