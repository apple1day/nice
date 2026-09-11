# 修复完成后遇到 pyexpat / libexpat 动态库错误

## 区分已经成功的步骤

如果日志已经显示：

```text
工程检查通过：所有 App/测试 Swift 文件均已加入正确编译目标。
Installing MobileVLCKit (3.7.3)
Pod installation complete!
```

之后才在 `project_doctor.py` 的工作区 XML 检查中出现：

```text
Symbol not found: _XML_SetAllocTrackerActivationThreshold
Expected in: /usr/lib/libexpat.1.dylib
ImportError: No module named expat; use SimpleXMLTreeBuilder instead
```

说明源文件成员修复和 CocoaPods 安装已经完成。失败的是宿主 Mac 上 Python 的 XML
解析扩展加载，不是 Swift 编译器、不是 VLC 安装失败，也不是视频文件损坏。
最后一行的 “No module named expat” 是次级错误，前面的动态库缺符号才是关键。

Homebrew 上游存在同样错误的报告，维护者指出它可能来自 Python 构建使用的 SDK 与
实际 macOS 提供的系统 libexpat 不兼容；当前日志并没有给出 macOS 版本，不能据此推断
用户的具体系统版本。参考：https://github.com/Homebrew/homebrew-core/issues/277330

## 本项目的修复

macOS 的工作区检查改用 `/usr/bin/xmllint`（libxml2）执行 XPath，**不再加载 Python 的
ElementTree/pyexpat**。`prepare` 和 `--sources-only` 同样不会导入 Python XML 解析器。
其他平台的测试才惰性加载 ElementTree。

仍然验证 XML 格式、Workspace 根节点、两个实际 FileRef 引用、依赖锁文件和 VLC framework。
不是跳过检查，也不是正则匹配文件名。XML 输入限制为 1 MiB 的 UTF-8，拒绝 DTD/自定义实体，
不使用 recover/noent/loaddtd，有超时限制；检查器失败时明确报错，不伪装成功。

此修复不修改 Python 安装、不设置全局 DYLD/PATH、不重签系统动态库、不更换 VLC 版本，
不要求 pip 安装 expat，也不需要重新安装 Xcode。宿主 Python 的问题会继续影响其他依赖
pyexpat 的工具，后续可单独处理；本项目绕开了这个依赖。

## 当前状态的最短恢复步骤

在仓库根目录、原开发分支中运行：

```bash
git pull --ff-only origin codex/ios-native-offline-video &&
python3 ios/tools/project_doctor.py check &&
open ios/NiceVideos.xcworkspace
```

期望增加输出：`工作区和 VLC 依赖检查通过。`
这次已经安装完成时无需重新生成工程或重新下载 VLC。检查不通过时按具体提示处理，
不要无条件跳过检查。需要完整重建时仍可使用 `bash ios/repair-project.sh`。

在 Xcode 选择 NiceVideos scheme 后重新 Build/Run；保持原 Bundle ID/Team，不卸载旧 App。

## 回归测试

```bash
python3 -m unittest discover -s ios/tools -p 'test_*.py' -v
```

新增 18 项工作区检查测试，包含：模拟 Python XML 全部无法导入，仍执行 macOS 原生
XML 检查；真实 macOS 进程中禁止导入 pyexpat/ElementTree，再校验完整工作区；错误 XML、
注释伪造引用、缺少引用、锁不一致、VLC 缺失、工具超时/缺失等仍然失败。
其中原生 macOS 测试在非 macOS 环境跳过，必须看 macOS CI 的实际结果。
