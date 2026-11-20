# Keylane 项目协作规范

本文件适用于本 Git 仓库内的所有文件。修改项目的 agent 必须遵守以下规则。

## 范围与来源

- Git 根目录为 `Keylane/`。上级目录的 `research/`、`work/` 等资料不属于本仓库，不得提交或打包。
- 保留用户未提交的改动，不得自行覆盖、清理、暂存或混入当前任务的提交。存在并行修改时，从已提交基线创建独立 worktree。
- 不得复制 SuperCMD、Raycast 的私有代码、图标、品牌素材或分发产物。参考公开源码时先核对许可，实际复用须保留所需声明；不得把第三方内容全部改标为本项目许可证。
- 不得提交密钥、用户数据、签名证书、本机签名身份、缓存或构建产物。构建产物仅通过 Actions artifacts 和 Releases 分发。

## 开发前澄清需求

- **先核对现状。** 开始改代码前，阅读用户本轮要求、相关实现和测试，核对已有决定、待办及同范围的在途 PR。修复问题时，先确认实际行为、期望行为和受影响的入口。现有证据足以回答的问题直接核实。
- **关键问题没明确，必须先问。** 如果存在多种合理理解，且选择会改变用户可见行为、交付范围或验收结果，先向用户澄清。重点核对功能入口、默认行为、权限、已有数据如何处理，以及成功和失败时应该发生什么。参考其他应用或截图时，确认要复现的具体交互和本轮范围，尤其是参考材料无法说明的部分。
- **问题要具体。** 把相关问题合并成一组，指出哪项决定缺失、各选项会带来什么实际差异。若已有明确授权或已确认的项目约定，直接沿用。例如，「完善自动退出」没有明确是否给所有应用默认启用时，应先问适用范围，再修改自动退出规则。
- **答复前只推进独立部分。** 等待关键问题的答复时，可以继续只读调查、复现问题和梳理验收用例。依赖该答复的代码、配置和用户数据变更，须等用户明确后再开始。开发中若发现新事实改变已确认的范围或行为，暂停受影响部分并重新确认。
- **实现细节由 agent 负责。** 需求已经明确时直接开发。可以依据仓库惯例自行决定可逆的实现细节，例如复用哪个共用组件或如何组织内部代码。开始修改前，用简短说明交代本轮目标、范围和验收方式。

## 分支与提交

固定流程：`功能分支 → dev → main`。

- `main` 是稳定分支，接收经过验证的 dev 同步快照；合入本身不发布；禁止直接提交或直接推送到 `main`。
- `dev` 是开发集成分支。新任务从最新 `origin/dev` 创建 `feat/<主题>`、`fix/<主题>`、`docs/<主题>` 或 `chore/<主题>` 分支；不得在 `dev` 上直接开发。
- 功能分支完成后先运行相关检查，再通过 PR 合入 `dev`。PR 应说明功能变化、验证方式、未完成项及影响。CI 通过不代表已完成实机验收。
- 一批功能开发完成且必要的实际交互验证通过后，才能创建 **dev → main** 同步 PR。不得从其他功能分支直接合入 `main`。
- dev → main 同步 PR 使用 **Squash and merge**，保持单一快照提交；普通同步可使用 `chore:` 或 `docs:` 等准确标题，不强制伪造 release 标题。正式发布候选可用 `release: vX.Y.Z`，但该标题不会触发发布。
- 普通提交采用 `feat:`、`fix:`、`docs:`、`chore:`、`test:` 等清楚的前缀，保持单一目的，避免混入无关修改。
- 禁止强推 `main` / `dev`、改写公开标签或删除已发布版本。修复已发布问题应从功能分支合入 dev，再按原发布渠道发布新版本。正式版修复通过 dev → main 发布。
- 正式版发布后将 `main` 合回 `dev`（通过同步 PR），再继续从更新后的 `dev` 开发，避免 squash 导致版本基线漂移。

## 设置页

- 新增设置页从模块登记，常规分组、命令行和目录操作复用现有设置组件。设置宿主统一导航、工具栏和滚动。接入示例见 `docs/LAUNCHER-ARCHITECTURE.md` 中的「应用程序」和「截图」。
- 有名称、别名、快捷键和启用状态的列表统一用 `CommandSettingsList`，页面只提供条目和动作。应用程序与文件搜索的搜索范围统一用 `SettingsSearchScopeCard`；搜索范围和忽略规则共用 `SettingsListCard`、`SettingsCompactList` 与 `SettingsCompactItemRow`。修改这些共用组件时，在安装版对照应用程序、快捷指令和截图的行高、控件对齐和分隔线。
- 设置行优先通过 `SettingsRow(title, detail:)` 提供文字，自定义布局使用 `SettingsTitle` 和 `SettingsDescription`，由组件统一标题层级、说明字号和换行。
- 可搜索的分组复用登记用的 `SettingsItem` 作为定位锚点。修改页面结构时复验搜索跳转、键盘操作和深浅色样式。涉及长列表时，用同一批数据对照切页与滚动。

## AI 会话与界面

- Quick AI 和 AI Chat 共用 `AIConversationSession`、`AIConversationComposer`、`AIConversationRepository`、消息和附件模型；新增发送、停止、重试、历史或模型策略先在公共层实现，不在某个窗口另写分派链。
- 思考/工具过程、添加附件菜单、原生输入、附件导入和消息展示复用现有 `AIConversation*` 组件，通过紧凑配置适配 Launcher。系统 sheet、剪贴板、导出和确认弹窗留在宿主；生成与存储状态不依赖 AppKit。
- 变更消息编码须兼容旧 `files` 与 `attachments`；补测活动请求转入完整窗口不重复发送、草稿/附件保留和各异步代次失效。架构与验证边界见 `docs/AI-CONVERSATION-ARCHITECTURE.md`。
- 内置模块的 AI 动作使用普通 CommandID 和 `LauncherModule.aiActions` 登记，来源由模块提供 `AIActionSource`；不得在菜单或视图中直接读取全文并另写请求循环。聊天和模块动作共用 `AIRunHandle`，结果复用公共 Markdown／过程组件。样板与额度见 `docs/AI-MODULE-ACTIONS.md`。
- AI 输入只在显式调用后准备，发送前重查来源、命令和模型；逐片段更新不得转发根搜索评分。加入聊天草稿须保留现有草稿和附件，不因路由进入而自动提交。停用后重新启用不能复活旧调用。
- 聊天上下文通过所属模块的 `LauncherModule.aiContexts` 登记；目录只提供元数据和 `AIActionSource`，选中后才读取正文。使用注册表包装的模块／功能代次，不在聊天宿主添加模块 switch，不在读取目录时做 OCR、权限请求或网络操作。来源读取与核对在主线程进入，耗时提取交给可取消后台任务。
- 聊天 `/` 菜单复用注册表的 AI 命令投影，内置动作使用 `aiActions`，动态命令提供方用 `isAICommand` 标记；仍按普通 CommandID 执行。结果复用 `AIResultContent`／`AIActionResultView`，不另写 Markdown 或过程展示；命令切换保留已有会话和草稿，但不得自动发送。


## 版本规范

- `version.json` 是版本和构建号的唯一来源；不得在打包脚本中另写固定版本。
- `version` 使用 `MAJOR.MINOR.PATCH`，不带 `v`，不带前导零；`build` 为正整数。
- 普通 dev → main 同步不要求提升版本或构建号。正式发布候选必须提升版本和构建号：版本大于之前正式版，构建号大于所有已公开正式版及预发布。不得复用已发布版本号。
- 修复用 PATCH，向后兼容功能用 MINOR，不兼容变化用 MAJOR。开发分支可沿用当前开发版本；发布 PR 前统一更新。
- 正式发布候选如使用 `release: vX.Y.Z` 标题，应与 `version.json` 一致。说明已验证的功能、已知限制、兼容性和是否已签名/公证。
- 只有独立 `Release` 工作流的 `workflow_dispatch` 入口可发布：选择 main 并显式输入与该运行提交一致的完整 `target_sha`，检查、签名、公证及制品验证后创建对应 `vX.Y.Z` 标签及 GitHub Release；版本、应用 Info.plist、DMG 文件名和标签必须一致。
- 当前已有历史提交早于此规范；本规范约束启用后的发布，不要求重写旧历史。

## Alpha、Beta 与正式版

Alpha 和 Beta 是同一个开发里程碑的两个阶段。需要公开试用的里程碑按 `Alpha.1 → Alpha.2 → … → Beta.1 → Beta.2 → … → 正式版` 推进，具体发布次数由改动和反馈决定。处于快速迭代时，先持续发 Alpha，等主要功能和本轮范围稳定后再进入 Beta。正式版之后的修复和小更新，可按改动范围完成验证后直接发布，不要求为每个版本重走 Alpha 和 Beta。

| 渠道 | 标签 | 发布来源 | 验收条件 |
| --- | --- | --- | --- |
| Alpha | `vX.Y.Z-alpha.N` | 已合入 `dev` 的确定提交 | CI 的测试、构建和安装包检查通过；至少验证应用可启动，以及本轮主要改动的基本流程。可以包含未完成的功能，需说明已知问题。 |
| Beta | `vX.Y.Z-beta.N` | 已合入 `dev` 的确定提交 | 本轮功能范围基本稳定，主要功能可试用。首次 Beta 验证核心流程，后续 Beta 重点回归改动及受影响的流程。 |
| 正式版 | `vX.Y.Z` | 通过 dev → main PR 合入的确定提交 | 里程碑版本在 Beta 中验证稳定后发布。直接发布的修复和小更新，验证改动及受影响流程。发布 PR 记录测试结果和已知限制。 |

- 同一阶段可以连续发布多个版本，无需为每次提交都发布。进入 Beta 后以修复和打磨为主，新功能通常留到下个里程碑。测试由维护者按风险安排，可复用前序验证结果，对变化的部分补做回归。
- `X.Y.Z` 为目标正式版本，与该提交的 `version.json` 一致。`N` 是从 1 开始的正整数，同一目标版本的 Alpha 和 Beta 各自递增。预发布后缀只用于标签和 GitHub Release 标题，`version.json`、应用版本和构建产生的 DMG 文件名仍使用现有数字版本格式。
- 对外发布的 Alpha、Beta 和正式版各使用新的构建号，构建号须大于此前公开发布的构建号。修复后发布下一序号，已发布的标签和产物保持可追溯。
- Alpha 和 Beta 使用 GitHub **Pre-release**，不设为 Latest，不需要合入 `main`。正式版按 `dev → main` 流程发布。预发布包和正式包分别从各自标签对应的提交构建。
- 预发布前确认对应 `dev` 提交的 CI 已通过，使用同一提交的 Apple Development 签名 DMG 和 SHA-256 文件。发布说明列出对应提交、主要改动、测试范围、已知问题、系统要求及签名／公证状态。
- 每次正式版和预发布在候选提交中保存 `docs/releases/<标签>.md`，参照 [发布说明模板](docs/releases/TEMPLATE.md)。首行用具体发布主题，正文在「新增」「改进」「修复」中按模块逐条写入口、行为或修复场景，省略无内容的分类，并写明「兼容性与已知限制」和「验证」。逐项核对上一个公开版本之后已合入的用户可见改动，注明未验收项。
- 发布前运行 `python3 scripts/check-release-notes.py <标签>`。正式版 CI 会校验并使用该文件生成 Release 正文；手动预发布也从文件生成正文，并补充实际构建提交、平台、签名／公证状态和工件说明。应用内更新日志读取同一份 GitHub Release 正文。
- 普通 PR（同仓库和 fork）仅运行无密钥 Checks，不签名、不构建或上传测试 DMG。只有合入 dev/main 后的 push 在 Checks 成功且安装包验证范围需要时进入 `preview-signing-auto`，固定该提交生成 Apple Development 签名测试包。手动 CI 不签名。环境必须只允许 Branch dev/main，不允许 PR refs 或 tag，且不得依赖 PR 可修改的 YAML 条件。`KEYLANE_PREVIEW_P12` 和 `KEYLANE_PREVIEW_P12_PASSWORD` 仅由用户直接配置到受保护环境，禁止仓库/组织级 fallback。缺少凭据时失败，无临时签名回退、无自动 Release/tag；环境设置变更须另行确认。详见 `docs/PREVIEW-SIGNING-APPROVAL.md`。

## 检查与交付

修改前阅读 `Package.swift`、相关实现及 `docs/` 验证记录；项目要求 macOS 26+ 和 Swift 6。

基本检查：

```sh
python3 scripts/check-version.py
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
swift test --scratch-path .build-current --disable-sandbox
bash scripts/package.sh
python3 scripts/verify-package.py
```

- 无开发证书的隔离构建可显式使用 `KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh`。临时签名不得描述为 Developer ID 签名或 Apple 公证。
- 涉及文件访问、剪贴板、快捷键、自动粘贴、窗口、分享、AI 等系统行为时，补充相关集成验证及必要实机验收；不得把合成或模拟结果写成真实服务验证。
- README 与开发记录应区分已实现、自动化验证、实机验收和未完成项。
- 发布前检查仓库只包含允许公开的代码与资料；产物包含许可证，且无第三方研究素材或用户数据。
- Actions 的 `Checks` 必须通过。失败时定位并修复，不得以删测试、跳过检查或放宽发布条件掩盖问题。
- CI 保留分支保护所需 `Checks` 名称，对所有 PR 和 dev/main push 运行版本、脚本检查及 Swift 编译测试。main PR 只允许同仓库 dev 来源；普通同步不强制 release 标题、版本递增或发布说明。改动 workflows、scripts、Resources、Swift 包配置、许可证/第三方声明或 version.json 时按上述规则验证 Apple Development 签名 DMG；未知 push 基线保守执行打包。手动 CI 不签名或打包；PR 仅执行无密钥检查。CI 无发布权限，签名 secrets 仅供签名打包任务使用。
- 正式发布仅手动运行 `.github/workflows/release.yml`，固定 main 提交，重新执行版本/构建号、发布说明、脚本、Swift 测试、Developer ID 签名、公证和票据验证。只有全部成功后 publish job 才获得 contents:write；不可覆盖其他提交的 tag 或已发布资产。不得使用普通 push 或 workflow_run 自动发布。未完成验证前，不得宣称支持 Intel 或通用二进制。

## 模块 AI 结果与生成

- 优先使用 `ModuleAICommands` 接入新的模块动作；业务模块负责来源与结果校验。片段转换不展开模板，并校验占位符原文／数量；Emoji 结果必须映射到本地目录。
- 需要校验的结果使用公共会话的缓冲策略，不提前显示或复制未经验证的流式原文。保存／展示结果用 `AIActionDefinition.resultDestination` 指向普通命令；新建预览仍由用户明确保存，不直接修改源记录。
- 内部结果展示命令标记 `isInternal`，不列入搜索和热键设置；不要为 UI 结果操作建立另一套绕过注册表的分派链。
- `AIActionOutput.text` 是用户可读结果，内部结构参数放入 `commandArgument`；不要将传输 JSON 或协议字段直接显示给用户。结果动作必须以成功完成状态为准，不能仅凭存在部分正文判断可执行。

- 读取私人数据的 AI 工具须复用 `AIToolRun` 逐次确认与运行域；模型只能通过本次搜索返回的临时引用读取正文，不能直接传文件路径或数据库 ID。`snapshotAvailability` 在目录快照时冻结功能代次，停用／重新启用不能恢复旧权限。授权范围与文件版本由业务模块校验；声明目录不读正文、不申请权限。样板见 `AIReadTools` 与 `docs/AI-MODULE-ACTIONS.md`。
