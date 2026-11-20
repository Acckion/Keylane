# 当前场景快捷键地图验证（2026-11-20）

## 实现范围

- 复用 Launcher 现有 ANSI 键盘、顶部绑定入口和命令选择器；应用和来源筛选在键盘上方，选择详情在下方滚动。
- 默认读取打开 Launcher 前的应用，可选择其他运行应用和手动刷新。按修饰键预览，点击或录入组合查看详情，不执行菜单操作。
- 应用菜单沿用 SystemNavigation 扫描。优先使用 AX 物理键码；部分原生菜单只提供文字时，按当前 ASCII 兼容键盘布局解析，不假定 US 布局。
- 使用 CopySymbolicHotKeys 读取启用的系统组合。不从数组下标猜操作名称；不支持显示的组合明确提示。保留辅助功能授权及菜单排除设置。
- 录制与绑定前显示外部已知冲突，提交前刷新；应用内重叠需确认。Keylane 原有改绑检查继续生效。只有 Carbon 明确返回重复注册时，才提示外部全局注册占用，不猜所属应用。
- 扫描取消、超时、切换目标和保存前检查均拒绝旧结果。没有通过遍历注册快捷键进行探测。

## 已完成检查

- 完整应用编译通过。
- Swift 全量测试：324 项通过。包含新增 AX 修饰键转换、按应用区分冲突、停用条目、全局来源与注册错误分类测试。
- 发布相关 Python 测试：27 项通过；版本检查通过。
- 隔离的 ShortcutMapController 检查通过：切换目标取消旧扫描、迟到结果拒绝、超时只完成一次、停用条目不冲突、权限不足、排除应用和拒绝宿主自身。仅使用临时偏好设置域，不执行菜单动作。
- 原有导航完整集成检查曾通过（测试应用窗口、嵌套菜单、动态菜单刷新、禁用命令、测试文件粘贴和取消）。补充物理键检查后一次重跑在既有前台窗口布局检查失败，未因此改动或放宽布局逻辑。
- 单独的真实原生菜单检查 `navigation-check --shortcut-map-only` 通过：确认 Shift-Command-J 的物理键码和修饰键、嵌套菜单路径，且没有执行菜单动作。此入口保留在导航集成测试中，可避开无关窗口布局操作。
- 本机系统读取探针成功：系统返回 234 个条目，其中 162 个启用；57 个可由当前键盘修饰键集合表示。其余含 Fn 等组合，界面注明未完整显示，不将其视为空闲。

## 重现控制器检查

以下命令只编译测试，读取系统快捷键，并通过注入菜单快照验证控制器；Finder 用作存活目标身份，不对 Finder 执行操作。

```sh
task_dir=$(mktemp -d /private/tmp/keylane-shortcut-check.XXXXXX)
swiftc -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path "$task_dir/cache" \
  -emit-module -emit-library -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 \
  -emit-module-path "$task_dir/KeylaneCore.swiftmodule" -o "$task_dir/libKeylaneCore.dylib"
swiftc -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path "$task_dir/cache" \
  -I "$task_dir" -L "$task_dir" -lKeylaneCore -Xlinker -rpath -Xlinker "$task_dir" \
  Sources/Keylane/SystemNavigation.swift Sources/Keylane/ShortcutMapController.swift \
  Tests/Integration/shortcut-map-main.swift -o "$task_dir/map-check"
"$task_dir/map-check"
```

真实菜单映射检查使用 `scripts/verify-navigation.sh` 中相同的编译方式生成 navigation-check，再传 `--shortcut-map-only`；需要测试宿主有辅助功能权限。没有权限时测试会明确跳过原生部分，不能算原生验证通过。

## 尚未验收与系统边界

本轮尚未安装到 /Applications，也尚未完成安装版键盘详情区、来源切换和录制确认的人工视觉验收。

macOS 未提供统一接口枚举所有应用私有的全局或内部快捷键。未发现已知冲突不保证空闲；系统返回的部分组合缺少操作名称。应用菜单数据也可能不完整，界面保留说明。菜单当前不可用的条目仍显示，但不作为当前已知占用。
