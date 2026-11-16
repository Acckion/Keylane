# Issue #76：自动退出搜索弹窗与卸载预览

范围来自 [输入故障评论](https://github.com/Acckion/Keylane/issues/76#issuecomment-6905943310) 和 [卸载界面对照评论](https://github.com/Acckion/Keylane/issues/76#issuecomment-6905972431)。已查看三张截图：输入故障位于「设置 → 应用程序 → 自动退出 → 右上角＋ → 搜索应用…」，不是卸载确认框。卸载要求是将系统 NSAlert 改成 Keylane 内的文件选择页。本修复已无冲突同步到 dev `ace5f90`（含 #140），不涉及发行或其他设置功能。

## 实现与证据边界

`ApplicationAutoQuitAddButton` 原来将 `open`、`query`、`options` 与错误提示一起保存在 SwiftUI 工具栏弹窗宿主。工具栏更新与弹窗的输入状态耦合；AppKit 弹窗的焦点归属也需要按实际事件窗口处理，不能只用 `NSApp.keyWindow` 判断。该属性在 popover 已为 key 的情况下仍可能返回父窗口。

现在两个设置选择器使用原生 NSButton/NSPopover 管理展示、关闭及显示完成后的焦点，目录观察、搜索、选项与错误状态由弹窗内容持有。关闭释放内容，重新打开时搜索为空。保留既有 `SearchField`；IME 检测优先读取当前事件窗口的 field editor，避免误读父窗口。未增加全局按键监听或吞掉普通文字。

证据边界：早期隔离夹具通过 CUA `pressKey("d")` 复现菜单关闭，但该通道在修改后仍将文字送入父搜索框，因而不能独自证明代码根因或实际键盘修复成功。最终夹具通过 LaunchServices 启动，在 NSApplication 主事件循环中确认 popover 自身为 key，并通过应用级原生事件断言。CUA `typeText("demo")` 确认弹窗保持打开并正确筛选；实体键盘与真正输入法仍需维护者验收。

## Keylane 卸载预览

原有应用动作和「卸载应用程序」命令均进入登记的 Keylane 预览页。列表显示应用及关联文件的名称、所在目录、可获取的单文件大小与图标，支持搜索、按路径/名称排序、逐项勾选、方向键定位与操作菜单中的「勾选或取消所选文件」。回车或底部动作提交当前完整选择；返回取消预览。

- 仅应用默认勾选，关联文件保持默认不勾选。取消应用勾选后不能提交；本页不支持仅清理残留。
- 搜索隐藏的勾选项仍属于选择，顶部计数始终统计全部选择。无匹配结果不会改变选择。
- 目录大小显示 `—`，不递归读取应用数据估算体积；这不是截图中完整磁盘占用统计的实现。
- 确认只能提交一次；离开预览使未提交回调失效。后台操作完成时只清理对应预览，不打断其他页面。
- 保留原有运行状态、应用文件身份、bundle ID 与共享副本复核，以及 `ApplicationLeftovers` 的目标身份检查。应用模块关闭或预览页不可用时不再展示已完成扫描的过期结果。
- 文件移动仍走原有废纸篓流程。系统拒绝和部分残留失败仍使用原有反馈；本次未执行真实卸载来验收这些分支。

## 验证

环境：macOS 27.3（26C5035r），arm64。自动化结果与实体操作分开记录。

- 最终代码 `swift test --scratch-path .build-current --disable-sandbox`：161 项通过，0 失败。
- `python3 scripts/check-version.py`、18 项 `Tests/ReleaseTests`、脚本 `bash -n`、`git diff --check`：通过。
- `scripts/verify-application-menu-ui.sh`：在临时 home、独立 bundle ID 和假应用中编译生产代码，只替换程序入口。未启动 Delegate 服务；卸载预览的确认/取消使用记录回调，绝不调用真实删除处理。状态断言覆盖默认选择、筛选保持隐藏勾选、键盘定位后切换、取消应用后的提交禁止、选择快照、重复提交禁止与取消幂等。
- 同一夹具的原生 AppKit 窗口断言通过：普通字母、退格、原生 marked text、中文提交、ESC、重新打开清空搜索、下/上/下/回车只选中对应假应用、选择后关闭、无结果回车不关闭、时长搜索与选择后关闭。事件经过夹具自身 NSApplication 分发，不向系统事件流注入；同时检查可见 popover 自身的 key 状态。完整通过输出见 [native-ui-regression.txt](evidence/issue-76/native-ui-regression.txt)。
- `KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh` 与 `python3 scripts/verify-package.py`：最终生产代码的 Apple Silicon DMG 构建、内容清单、元数据、许可证、架构与签名校验通过。临时签名、未公证；没有安装或发布。

夹具使用方式：默认参数运行断言并清理临时目录；`--prepare` 只构建并打印 app/home 路径；`--interactive` 保留临时目录并运行演示。使用 `--prepare` 的产物时，必须通过 `open -n --env CFFIXED_USER_HOME=<打印的home> <app>` 正常启动，隔离前置条件会校验 home 和 bundle ID。交互演示中的「演示确认」仅记录选择，不删除文件；不要将其当作真实卸载成功证明。

## 尚待验收

CUA 实机检查通过文字输入筛选、点击外部关闭、预览逐项勾选、计数及筛选保留隐藏选择，并查看了深色演示布局。应用级 `pressKey("d")` 仍关闭菜单并把文字送入父搜索框，原因未定；与正常事件循环的自动断言存在差异，不能宣称实体键盘已验收。实际中文输入法候选/组字/提交、安装版完整导航、深浅色完整对照与 VoiceOver 仍未完成。此前 CUA 多次 `Transport closed`；没有将合成 marked text 当作实际中文输入法验收。未操作真实应用卸载、清理真实用户文件、修改系统权限或覆盖安装。macOS 26 兼容性也未在本次设备上复测。Issue #76 应保持打开。
