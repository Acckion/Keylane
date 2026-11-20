# 动态目录事务（第三批）

前序：第一批 [#218](https://github.com/Acckion/Keylane/pull/218) 已合入 dev；第二批 [#221](https://github.com/Acckion/Keylane/pull/221) 为页面动作与会话收敛，已合入 dev。本分支现已同步 dev 8b2fa64，完成跨批编译与模块/动作/会话/目录集成回归；安装版撤销目录时的真实页面交互仍待验收。

对应 EXT-01、BASE-03、BASE-11。模块目录索引集中为一个不可变 CatalogSnapshot，catalogRevision 表示目录替换；Activation 的 UUID/代次表示运行实例。启用/禁用或注册状态变化无需伪装成目录替换；相同命令和页 ID 的版本替换也会撤销旧 Activation。

## 目录准备与提交

registry.install(module) 和 uninstall(id) 是宿主内部的逻辑目录入口，不下载文件或启动第三方安装脚本。

1. 先构建完整候选目录，校验模块、命令、页面、设置、provider 命名空间、AI 声明及页面/设置父引用。不会创建页面、申请权限或运行服务。
2. 校验失败直接抛错，原目录 revision、运行实例、服务、热键和订阅不变。
3. 校验通过后先撤销受影响旧实例和工具代次，通知宿主清理页面/热键，再停止该模块服务。
4. 一次替换索引快照、建立新运行实例、启动受设置允许的服务，并重绑注册、搜索、展示和快捷键设置订阅。
5. 发布 revision 与 registrationUpdates，复用宿主已有设置目录刷新、搜索失效和热键重建路径。旧模块的流不再转发，未变化的模块不重启。

提交期间拒绝嵌套目录修改，也不允许通过服务回调切换模块启用状态。既有未注册的应用/内置模块不能被运行时 install/uninstall 替换；新增可信原生适配器和来宾适配器均须贡献 Registration，使用同一个目录入口。权限与执行信任边界仍由适配器负责，来宾不能直接注入 Swift 闭包。

## 范围与失败语义

这里的回滚是**目录准备失败不触碰旧状态**。生命周期 start/stop 是现有非抛错契约，本批不提供文件系统替换、跨进程崩溃或任意业务副作用的回滚。安装下载/验证应先在受控暂存区完成，再提交已经验证的声明；完整 Store 和应用内 JS 渲染仍是后续接入工作。

保留原设置键与用户禁用状态，卸载不清理用户偏好，重装不会复活旧 UUID 的回调。Registry 对象身份不变，因此窗口、设置和全局热键观察者不必切换到另一套注册表。

## 验证

模块注册集成覆盖新 ID/页面/设置插入、同 ID 替换、卸载、重装、旧调用和旧快捷键 scope 失效、旧搜索/快捷键设置订阅退出、新订阅生效、无效页面/父引用保留旧快照、不创建页面、原生/来宾声明入口一致、不可变内置模块保护和服务停止时重入拒绝。

适配器测试使用受控的 LauncherModule 声明，不是实际第三方扩展安装验收。完整构建与隔离结果单独记录；本轮未安装、发布或自动合并。

本批验证：目录事务/模块集成与完整应用构建通过（12.68 秒最终增量），版本检查通过；实机第三方安装与跨批集成仍待验证。

后续整合验证：同步 #221、#219 后完整应用构建通过（65.33 秒），合并两批测试后集成通过；未安装或自动合并。

## PR #223 审查修复：生命周期期间的注册事件

本次基线为 dev `fc44e8b5ea287811feccc6add20114bbc7011e13`，从远端 #223 `ff58af255d62a8731f22a113e11c946a90ea9d25` 同步。合并保留 AI 上下文/结果目标校验和隐藏内部命令规则：声明校验仍位于候选快照，运行期上下文监听随目录重绑。

修复 P2：提交期间的注册事件按 ModuleID 排队，不在 `updatingCatalog` 时丢弃；生命周期回调完成后协调到稳定状态，仍保持目录/激活协调的防重入边界。旧停止回调期间继续观察注册与上下文变化，避免遗漏其他模块的撤权。瞬时关闭再开启会记住撤销事实，立即阻止旧激活准入，随后撤销旧 UUID、停止服务并按最终元数据重建实例。公开通知引发的注册变化也会处理；无变化事件合并，不形成通知回声循环。

合成回归先在未修复版本确定性复现 `start-disable: lifecycle registration change was lost`。修复后新增 8 个启动/显示组合，以及跨模块联动、公开通知、旧模块停止时的瞬时撤权回归通过；覆盖撤销通知、服务退出、旧回调拒绝和最终激活状态。完整构建与 403 项 Swift 测试、27 项脚本测试通过。准确最终头与远端 Checks 结果记录在原 PR；没有安装、合并、发布或修改 #222/#226。

### #217 integration (2026-11-21)

Synchronized PR #223 with dev `7f6a01b`. Tool projection preserves #217's
`forRun()` feature-generation snapshot together with the catalog's module
activation and tool-generation checks. Directory preparation does not capture
provider leases or read content. Synthetic integration covers feature lease
revocation, same-ID replacement, registration disable/re-enable, uninstall and
reinstall; every captured old tool remains unavailable. No real model, user
clipboard, user file or external service is used.

Validation: full application build, 403 Swift tests, 27 release-script tests,
directory integration, AI read-reference integration and native file-tool
integration passed. The initial sandboxed Swift/read-reference attempts were
blocked by macOS bookmark/pasteboard services; the unchanged tests passed outside
the sandbox. The read-reference fixture uses the local Apple Development
certificate, verified before/after execution; the original application main is
never run and no installation is performed. Exact final head and CI are in #223.
