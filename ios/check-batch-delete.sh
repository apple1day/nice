#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v swiftc >/dev/null || { echo '需要 Swift 编译器（Xcode Command Line Tools 或 Swift for Linux）'; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/SelectionChecks.swift" <<'SWIFT'
import Foundation

@main
struct SelectionChecks {
    static func main() {
        var selection = BatchSelection()
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL: \(label)") }
            checks += 1
            print("PASS: \(label)")
        }
        expect(!selection.isSelecting && selection.tokens.isEmpty, "默认不选择任何项目")
        selection.toggle("a|1")
        expect(selection.tokens.isEmpty, "普通浏览模式点击不会积累选择")
        selection.begin()
        selection.toggle("a|1")
        expect(selection.contains("a|1"), "点击选中")
        selection.toggle("a|1")
        expect(selection.tokens.isEmpty, "再次点击取消选中")
        selection.toggleAll(in: ["a|1", "b|1", "b|1"])
        expect(selection.tokens.count == 2 && selection.allSelected(in: ["a|1", "b|1"]), "全选仅包含可见任务且去重")
        selection.toggleAll(in: ["a|1", "b|1"])
        expect(selection.tokens.isEmpty, "取消全选")
        selection.toggleAll(in: ["a|1", "b|1", "c|1"])
        selection.retainVisible(["b|1", "c|1"])
        expect(selection.tokens == ["b|1", "c|1"], "搜索后不保留隐藏选择")
        selection.retainVisible(["b|2", "c|1"])
        expect(selection.tokens == ["c|1"], "重新下载的新批次不继承勾选")
        selection.retainVisible([])
        expect(!selection.isSelecting && selection.tokens.isEmpty, "列表清空后退出选择模式")
        selection.begin()
        selection.toggle("a|1")
        selection.cancel()
        expect(!selection.isSelecting && selection.tokens.isEmpty, "取消选择不残留勾选")
        print("\(checks) selection checks passed. Not an iOS UI/background-transfer test.")
    }
}
SWIFT
swiftc -swift-version 5 NiceVideos/BatchSelection.swift "$work/SelectionChecks.swift" -o "$work/checks"
"$work/checks"
