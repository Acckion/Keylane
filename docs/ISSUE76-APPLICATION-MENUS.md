# Issue #76：自动退出搜索弹窗与卸载预览

范围来自 [输入故障评论](https://github.com/Acckion/Keylane/issues/76#issuecomment-6905943310) 和 [卸载界面对照评论](https://github.com/Acckion/Keylane/issues/76#issuecomment-6905972431)。已查看三张截图：输入故障位于「设置 → 应用程序 → 自动退出 → 右上角＋ → 搜索应用…」，不是卸载确认框。卸载要求是将系统 NSAlert 改成 Keylane 内的文件选择页。本修复基于 dev `2b445bc`，不涉及发行或其他设置功能。

## 根因与修复

`ApplicationAutoQuitAddButton` 原来将 `open`、`query`、`options` 与错误提示一起保存在工具栏按钮视图中。搜索文字更新会使 SwiftUI 重新构建 AppKit 工具栏宿主，连带撤下仍在输入的 popover。此前隔离 macOS 夹具使用原生产按钮与搜索组件、内存演示目录：重新打开有 Demo Alpha/Beta 列表的弹窗后，实体键 `d` 立即使其消失。安装版只检查到空列表输入 `a` 保持打开；不能将该次观察描述为安装版完整复现。

现在工具栏按钮只管理弹窗开关，目录观察、搜索、选项与错误状态由独立弹窗内容视图持有。时长菜单也将搜索状态移入内容，重新打开时从空搜索开始。继续使用已有 `SearchField`、原生 field editor 与 IME 生命周期；没有增加全局按键监听或吞掉普通文字。

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
- 同一夹具的原生 AppKit 窗口断言通过：普通字母、退格、原生 marked text、中文提交、ESC、重新打开清空搜索、下/上/下/回车只选中对应假应用、选择后关闭、无结果回车不关闭、时长搜索与选择后关闭。仅向夹具自己的窗口派发事件，不向系统事件流注入。完整通过输出见 [native-ui-regression.txt](evidence/issue-76/native-ui-regression.txt)。
- `KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh` 与 `python3 scripts/verify-package.py`：最终生产代码的 Apple Silicon DMG 构建、内容清单、元数据、许可证、架构与签名校验通过。临时签名、未公证；没有安装或发布。

夹具使用方式：默认参数运行断言并清理临时目录；`--prepare` 只构建并打印 app/home 路径；`--interactive` 保留临时目录并运行演示。使用 `--prepare` 的产物时，必须以打印的 `CFFIXED_USER_HOME` 启动，隔离前置条件会校验 home 和 bundle ID。交互演示中的「演示确认」仅记录选择，不删除文件；不要将其当作真实卸载成功证明。

## 尚待验收

修复后实体键盘、实际中文输入法候选/组字/提交、点击外部关闭、安装版菜单与卸载页完整导航、深浅色和 VoiceOver 仍未完成。CUA 多次返回 `Transport closed`，包括只读窗口清单；没有将合成 marked text 当作实际中文输入法验收。未操作真实应用卸载、清理真实用户文件、修改系统权限或覆盖安装。macOS 26 兼容性也未在本次设备上复测。Issue #76 应保持打开。
