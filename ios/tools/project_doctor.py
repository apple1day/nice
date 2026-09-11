#!/usr/bin/env python3
"""Check Xcode target membership and preserve signing during XcodeGen repair.

Python standard library only; plutil and xmllint are supplied by macOS. No
package installs, Git resets, application-data deletion, or key access occur.
On macOS, workspace XML is parsed by libxml2, NOT Python's optional pyexpat.
"""
import argparse
import datetime
import json
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "NiceVideos.xcodeproj"
WORKSPACE = "NiceVideos.xcworkspace"
WORKSPACE_REFERENCES = ("group:NiceVideos.xcodeproj", "group:Pods/Pods.xcodeproj")
WORKSPACE_MAX_BYTES = 1024 * 1024
SIGNING_KEYS = (
    "PRODUCT_BUNDLE_IDENTIFIER", "DEVELOPMENT_TEAM", "CODE_SIGN_STYLE",
    "CODE_SIGN_IDENTITY", "PROVISIONING_PROFILE_SPECIFIER", "PROVISIONING_PROFILE",
    "CODE_SIGN_ENTITLEMENTS",
)


def read_project(root):
    path = root / PROJECT / "project.pbxproj"
    if not path.is_file():
        raise ValueError("没有生成 Xcode 工程，请运行 bash ios/setup.sh。")
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise ValueError("工程无法解析，已停止以避免覆盖：" + result.stderr.strip())
    return json.loads(result.stdout)


def targets(project):
    return {
        obj.get("name"): obj for obj in project["objects"].values()
        if obj.get("isa") == "PBXNativeTarget"
    }


def configs(project, owner):
    objects = project["objects"]
    config_list = objects.get(owner.get("buildConfigurationList"), {})
    return {
        objects[key]["name"]: objects[key].get("buildSettings", {})
        for key in config_list.get("buildConfigurations", [])
    }


def signing_overlay(project):
    """Keep per-configuration signing, including settings inherited from project."""
    objects = project["objects"]
    inherited = configs(project, objects[project["rootObject"]])
    result = {}
    for name, target in targets(project).items():
        if name not in ("NiceVideos", "NiceVideosTests"):
            continue
        selected = {}
        for config, settings in configs(project, target).items():
            merged = dict(inherited.get(config, {}))
            for key, value in settings.items():
                if value not in (None, "", "$(inherited)", "${inherited}"):
                    merged[key] = value
            selected[config] = {
                key: value for key, value in merged.items()
                if key.split("[", 1)[0] in SIGNING_KEYS
                and value not in (None, "", "$(inherited)", "${inherited}")
            }
        result[name] = {"settings": {"configs": selected}}
    return result


def reference_paths(root, project):
    """Resolve groups instead of searching filenames in project text/comments."""
    objects = project["objects"]
    resolved = {}

    def walk(key, parent, ancestors):
        if key in ancestors:
            raise ValueError("工程分组存在循环引用。")
        obj = objects.get(key, {})
        tree = obj.get("sourceTree", "<group>")
        base = root if tree == "SOURCE_ROOT" else parent
        path = Path(obj.get("path", ""))
        current = path if path.is_absolute() else base / path
        if obj.get("isa") == "PBXFileReference":
            resolved[key] = current.resolve()
        for child in obj.get("children", []):
            walk(child, current, ancestors | {key})

    walk(objects[project["rootObject"]]["mainGroup"], root, set())
    return resolved


def source_errors(root, project):
    objects = project["objects"]
    paths = reference_paths(root, project)
    available = targets(project)
    errors = []
    for name in ("OfflineMediaPolicy.swift", "VLCPlaybackEngine.swift"):
        if not (root / "NiceVideos" / name).is_file():
            errors.append("源码未完整拉取：NiceVideos/" + name)
    for name, directory in (("NiceVideos", "NiceVideos"), ("NiceVideosTests", "Tests")):
        target = available.get(name)
        if target is None:
            errors.append("缺少 target：" + name)
            continue
        expected = {p.resolve() for p in (root / directory).rglob("*.swift")}
        compiled = set()
        for phase_id in target.get("buildPhases", []):
            phase = objects.get(phase_id, {})
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for build_id in phase.get("files", []):
                path = paths.get(objects.get(build_id, {}).get("fileRef"))
                if path is not None:
                    compiled.add(path)
        for path in sorted(expected - compiled):
            errors.append("未加入 " + name + " 的 Compile Sources：" + str(path.relative_to(root)))
        for path in sorted(compiled):
            if path.suffix == ".swift" and not path.is_file():
                errors.append("工程仍引用已不存在的源码：" + str(path))
    return errors


def workspace_references(workspace: Path) -> set:
    """Read required XML references without loading Homebrew pyexpat on macOS.

    CocoaPods writes UTF-8 workspace XML. Use a bounded, read-once input with
    no DTD/entity declarations; never repair malformed XML or skip validation.
    XPath evaluates actual FileRef elements, not comments or text matches.
    """
    with workspace.open("rb") as stream:
        data = stream.read(WORKSPACE_MAX_BYTES + 1)
    if len(data) > WORKSPACE_MAX_BYTES:
        raise ValueError("工作区 XML 超过 1 MiB，已停止检查。")
    try:
        text = data.decode("utf-8-sig")
    except UnicodeError:
        raise ValueError("工作区 XML 不是 CocoaPods 使用的 UTF-8 编码，请重新运行 setup.sh。") from None
    if "<!DOCTYPE" in text.upper() or "<!ENTITY" in text.upper():
        raise ValueError("工作区 XML 不允许 DTD 或自定义实体声明。")

    if sys.platform == "darwin":
        # Absolute system path avoids Homebrew's mismatched Expat/libxml paths.
        # No shell, recovery mode, DTD loading, or entity expansion is enabled.
        checks = ["boolean(/Workspace)"] + [
            "boolean(/Workspace//FileRef[@location='%s'])" % ref
            for ref in WORKSPACE_REFERENCES
        ]
        xpath = "concat(" + ", '|', ".join(checks) + ")"
        try:
            result = subprocess.run(
                ["/usr/bin/xmllint", "--nonet", "--xpath", xpath, "-"],
                input=text, capture_output=True, encoding="utf-8",
                errors="replace", check=False, timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError("无法运行 macOS XML 检查器 /usr/bin/xmllint：" + str(error)) from None
        if result.returncode:
            raise ValueError("工作区 XML 解析失败：" + result.stderr.strip()[-1000:])
        values = result.stdout.strip().split("|")
        if len(values) != len(checks) or any(v not in ("true", "false") for v in values):
            raise ValueError("工作区 XML 检查器返回了无效结果。")
        if values[0] != "true":
            raise ValueError("工作区 XML 根节点必须为 Workspace。")
        return {ref for ref, value in zip(WORKSPACE_REFERENCES, values[1:]) if value == "true"}

    # Cross-platform unit tests can use the standard parser. Import lazily so
    # even --sources-only and prepare never require Expat on any platform.
    try:
        from xml.etree import ElementTree as ET
        document = ET.fromstring(text)
    except ImportError as error:
        raise ValueError("Python XML 解析器不可用，请使用兼容的 Python 环境：" + str(error)) from None
    except ET.ParseError as error:
        raise ValueError("工作区 XML 解析失败：" + str(error)) from None
    if document.tag != "Workspace":
        raise ValueError("工作区 XML 根节点必须为 Workspace。")
    return {node.attrib.get("location", "") for node in document.iter("FileRef")}


def dependency_errors(root):
    errors = []
    workspace = root / WORKSPACE / "contents.xcworkspacedata"
    if not workspace.is_file():
        errors.append("缺少 .xcworkspace，请重新运行 setup.sh 安装 CocoaPods 依赖。")
    else:
        refs = workspace_references(workspace)
        for expected in WORKSPACE_REFERENCES:
            if expected not in refs:
                errors.append("工作区缺少工程引用：" + expected)
    lock = root / "Podfile.lock"
    manifest = root / "Pods/Manifest.lock"
    if not lock.is_file() or not manifest.is_file() or lock.read_bytes() != manifest.read_bytes():
        errors.append("Pods 未安装或锁文件不一致，请运行 setup.sh（不要 pod update）。")
    if not (root / "Pods/MobileVLCKit/MobileVLCKit.xcframework").is_dir():
        errors.append("缺少 MobileVLCKit.xcframework，请先安装依赖。")
    return errors


def prepare(root, output):
    spec = {"include": ["project.yml"]}
    project_path = root / PROJECT
    if project_path.exists():
        project = read_project(root)  # Stop before overwriting an unreadable project.
        if "NiceVideos" not in targets(project):
            raise ValueError("原工程没有 NiceVideos target，已停止自动覆盖。")
        spec["targets"] = signing_overlay(project)
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = root / ".project-backups" / (stamp + "-" + uuid.uuid4().hex[:8])
        backup.mkdir(parents=True)
        for name in (PROJECT, WORKSPACE):
            if (root / name).is_dir():
                shutil.copytree(root / name, backup / name)
        print("原工程已备份：" + str(backup))
        print("将保留各配置的 Bundle ID、Team 和签名设置。")
        for error in source_errors(root, project):
            print("修复前：" + error)
    output.write_text(json.dumps(spec, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "prepare"))
    parser.add_argument("--sources-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            if args.output is None or args.output.resolve().parent != ROOT:
                raise ValueError("生成的临时 spec 必须在 ios 目录内，防止相对源码路径偏移。")
            prepare(ROOT, args.output)
            return 0
        errors = source_errors(ROOT, read_project(ROOT))
        if not args.sources_only:
            errors.extend(dependency_errors(ROOT))
        if errors:
            for error in errors:
                print("error: " + error, file=sys.stderr)
            print("error: 保存并关闭 Xcode，在仓库根目录执行 bash ios/repair-project.sh。", file=sys.stderr)
            return 1
        print("工程检查通过：所有 App/测试 Swift 文件均已加入正确编译目标。")
        if not args.sources_only:
            print("工作区和 VLC 依赖检查通过。")
        return 0
    except (OSError, ValueError, KeyError) as error:
        print("error: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
