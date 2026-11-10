# Phase 1 搜索回归修复 — 0.5.2

Phase 2 暂停。用户报告中文候选输入失败、英文搜索错误且结果总显示 AppCleaner，原 Phase 1 验收因此重新打开。

## 实际复现

- 0.5.1 使用自定义 AppKit 输入桥：输入 Terminal，实际字段只保留 al。
- 改回标准 SwiftUI TextField 后：Terminal 完整显示，动作菜单上下文为 Terminal，但结果列表仍错误显示 AppCleaner。
- 结果列表同时使用结果自身 ID 与行号 .id(index)。去掉行号身份、滚动也改用结果自身 ID 后，Terminal 字段对应 Terminal 结果，CUA 已验证。
- 查询替换测试发现 Command+A 未全选，Calculator 被追加成 TerminalCalculator；原程序没有标准 Cocoa 编辑菜单。

## 最终修改

- 移除自定义 NSTextField 的模型回写与选区控制，由系统 TextField 管理编辑器、选区和输入法。
- marked text 存在时不执行启动器上下、回车及 Escape 行为，交给系统处理。
- 结果行使用稳定结果 ID，避免过滤后复用旧结果显示与操作闭包。
- 补齐标准编辑菜单，通过 responder chain 提供全选、剪切、复制、粘贴、撤销、重做。
- 修复包 0.5.2 已安装并通过临时签名检查；原生菜单补丁编译通过。

## 验证边界

已验证：修复输入同步后 Terminal 完整保留；修复结果 ID 后 Terminal 显示正确结果，不再是 AppCleaner。

尚未验证：最终补齐菜单后的 Command+A 替换、Backspace/Delete、连续英文查询、中文真实候选词确认/取消及提交、菜单搜索回归。

最后安装完成后，CUA 报告 Mac 锁屏，需要用户手动解锁才能继续。不得把中文候选输入仅凭代码分支标记为修复通过。

## 0.5.3 后续实机结果

标准编辑菜单补丁已通过 Command+A 连续替换查询验证；System Settings、Terminal、xitongshezhi 均完整保留并显示对应结果，不再复用 AppCleaner。中文应用名称问题已单独修复，见 LOCALIZED-APP-NAMES.md。中文文本粘贴与检索通过；真实中文候选词交互仍不据此宣称完成。
