# Keylane 全仓库功能跟踪

维护基线为 2026-11-21 的 `dev` 提交 [9e73f01](https://github.com/Acckion/Keylane/commit/9e73f014ea7b38ff0bff3c4f34010d73e865cbce)。长期目标是逐步覆盖 Raycast 的功能，优先跟进 macOS 桌面体验。核对范围包含当前 Raycast 官方手册、仓库实现、模块文档和在途 PR。

这份总表记录当前实现与剩余工作。[TODO](TODO.md) 继续保存细项差异、历史排期及验收用例，模块文档保存设计和验证证据。[历史功能清单](archive/FEATURES.csv) 保留原始计划。发现状态冲突时，核对代码和 PR 后更新本表，并在旧条目旁注明日期及新证据。

## 状态与维护方式

| 字段 | 含义 |
| --- | --- |
| 已实现 | 该行限定的能力已合入基线，证据列可定位到实现或模块说明 |
| 部分实现 | 已有可运行部分，剩余差异列继续追踪 |
| 未实现 | 已核对的文档明确列为未接入，或仍只有占位入口 |
| 待核对 | 已收录参考能力，尚无足够依据确认现状及完整差异 |
| 评估中 | 存在实验或方案，尚未形成当前基线中的可用功能 |
| 待合并 | 仅在在途 PR 中，合并后再核对实现状态 |
| 待确认范围 | 已收录长期目标，但涉及此前范围决定或额外平台，开发前确认 |

实现状态与验收状态分别记录。“已有验证记录”表示证据列有自动化或隔离原生验证，安装版、真实权限或账户的剩余场景仍看对应记录。“待核对”不等同于已经确认缺失。暂不计算整体完成百分比，表中各行的工作量不同。

每个功能保留稳定编号。后续 PR 在说明中引用编号，更新实现状态、剩余差异、验收证据和日期。只有合入目标基线后才能将“待合并”改为“已实现”或“部分实现”。完成一个入口时，同步核对主搜索、独立页面、设置、菜单、热键、权限和重启后的行为。

## 启动器、搜索与键盘

参考 [搜索](https://manual.raycast.com/search-bar)、[操作面板](https://manual.raycast.com/action-panel)、[别名与热键](https://manual.raycast.com/command-aliases-and-hotkeys)、[Hyper Key](https://manual.raycast.com/hyper-key) 和 [v2 功能](https://manual.raycast.com/new-in-v2)。

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| BASE-01 | 主搜索、应用/文件/命令统一检索 | 部分实现 | 持续核对排序、收藏、备用命令、中文输入与性能 | 已有验证记录；[架构](LAUNCHER-ARCHITECTURE.md)、[细项](TODO.md) |
| BASE-02 | 紧凑模式、展开/收起、横向页面切换 | 已实现 | 实际键盘、减少动态效果、多显示器回归 | 安装版观感待持续验收；[交互](LAUNCHER-COMPACT-NAVIGATION.md) |
| BASE-03 | 标准操作面板、菜单搜索与键盘导航 | 部分实现 | 所有内置及第三方入口逐项接入公共组件 | 已有验证记录；[架构](LAUNCHER-ARCHITECTURE.md) |
| BASE-04 | 命令别名、热键、启用状态 | 部分实现 | 确认左右修饰键、fn、冲突、IME 与实体键盘支持边界 | [实现](../Sources/Keylane/ShortcutSettingsPreferences.swift)、[细项](TODO.md) |
| BASE-05 | Hyper Key、双击与导航绑定 | 部分实现 | 对照物理键映射、短按及 Secure Input 行为 | 实机待验收；[历史清单](archive/FEATURES.csv) |
| BASE-06 | 设置全文搜索、定位到模块与命令 | 已实现 | 新增设置页持续补搜索关键词与定位锚点 | [设置入口](../Sources/Keylane/Settings.swift) |
| BASE-07 | 共用菜单栏条目与生命周期 | 已实现 | 新模块复用登记、更新、注销和可见性设置 | 已有实机及隔离记录；[菜单栏](MENU-BAR-CALENDAR.md) |
| BASE-08 | 主题与自定义主题导入/共享 | 待合并 | Theme Studio 三栏编辑、滚动交互预览、深浅色分配、JSON/链接导入共享已在功能分支实现；使用 Keylane 自有主题格式，完整安装版验收仍待完成 | [实现与验证](features/THEME-STUDIO.md)、[issue #196](https://github.com/Acckion/Keylane/issues/196)、[PR #220](https://github.com/Acckion/Keylane/pull/220)；已通过隔离交互、341 项 Swift 与 27 项脚本测试，本机安装与签名已核对；审查增加紧凑栏主题透明间隙与独立表面回归 |
| BASE-09 | 通用动态占位符及修饰符 | 部分实现 | 片段、快捷链接分别支持部分语法，核对共用解析与完整修饰符 | [片段](SNIPPETS.md)、[快捷链接](QUICKLINKS.md)、[参考](https://manual.raycast.com/dynamic-placeholders) |
| BASE-10 | 首次引导、权限、辅助使用与本地化 | 部分实现 | 持续核对默认状态、拒绝/撤销、VoiceOver、对比度和中文输入 | [协作规范](../AGENTS.md)、[架构](LAUNCHER-ARCHITECTURE.md) |
| BASE-11 | 启动/查询性能、内存与后台生命周期 | 部分实现 | 使用可重复工作负载，分别记录耗时、内存与功能回归 | [历史验证证据](evidence/)、[细项](TODO.md) |

## 应用、文件与个人资料

各行仅记录指定能力。模块级“部分实现”还包含未闭环的使用场景，细项差异沿用 [TODO](TODO.md)。

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| APP-01 | 应用发现、拼音搜索、收藏及刷新 | 部分实现 | 外置/网络卷、扫描深度和失效路径继续验收 | [应用生命周期](APPLICATION-LIFECYCLE.md)、[Raycast](https://manual.raycast.com/applications) |
| APP-02 | 应用正常退出、卸载与残留预览 | 部分实现 | 应用差异、拒绝权限及残留范围逐项验收 | [卸载](UNINSTALL-PREVIEW.md) |
| APP-03 | 按应用闲置自动退出 | 部分实现 | 各应用保存对话框、退出拒绝和重启恢复实测 | [生命周期](APPLICATION-LIFECYCLE.md)、[Raycast](https://manual.raycast.com/auto-quit) |
| FILE-01 | 文件检索、筛选、预览与文件信息 | 部分实现 | 搜索范围、内容索引、排序和大型目录继续对照；索引清理与事务计数优化待合并，安装版能耗待复验 | [细项](TODO.md)、[Raycast](https://manual.raycast.com/file-search) |
| FILE-02 | 文件打开方式、分享、复制、定位等动作 | 部分实现 | 真实分享服务、取消、权限与焦点验收 | [细项](TODO.md) |
| CLIP-01 | 剪贴板历史、持久化、搜索及 OCR | 部分实现 | 真实跨应用粘贴、采集边界和隐私设置回归 | [实现](../Sources/Keylane/ClipboardActions.swift)、[细项](TODO.md)、[Raycast](https://manual.raycast.com/clipboard-history) |
| SHOT-01 | 截图/录屏管理、OCR、搜索与文件动作 | 部分实现 | 跨应用分享、粘贴、云盘和权限验收 | [截图](SCREENSHOTS.md)、[Raycast](https://manual.raycast.com/screenshots) |
| SHOT-02 | 截图捕获入口 | 已实现 | 核对不同捕获方式、快捷键及输出选择 | [截图](SCREENSHOTS.md) |
| SHOT-03 | 截图标注与图片编辑 | 待核对 | 原长期计划保留，先确认编辑器现状和工具清单 | [原计划](archive/FEATURES.csv) |
| CAL-01 | 日程浏览、筛选、菜单栏与入会 | 部分实现 | 会议客户端、实际邀请状态、自动入会及唤醒验收 | [日历](MENU-BAR-CALENDAR.md)、[差异](TODO.md)、[Raycast](https://manual.raycast.com/calendar) |
| CAL-02 | 新建/编辑日程、提醒、受邀人与空闲时间 | 部分实现 | 多账户邀请送达、重复事件和回复邀请动作 | [差异](TODO.md) |
| CONTACT-01 | 联系人搜索、字段动作及系统通讯录集成 | 部分实现 | 真机首次授权、编辑与删除等操作边界复核 | [模块](../Sources/Keylane/ContactsLauncherModule.swift) |
| NOTE-01 | Apple 备忘录搜索、新建与原生编辑 | 部分实现 | 常用账户、授权恢复和安装版快捷键验收 | [Apple 备忘录](APPLE-NOTES.md) |
| NOTE-02 | Raycast Notes 式独立笔记体验 | 待确认范围 | 现有选择是集成 Apple 备忘录，单独记录笔记/浮窗/同步差异 | [当前方案](APPLE-NOTES.md)、[Raycast Notes](https://manual.raycast.com/notes) |
| LINK-01 | 快捷链接集合、参数、标签、置顶及迁移 | 部分实现 | 网站图标、模板、浏览器标签及临时打开方式 | [快捷链接](QUICKLINKS.md)、[差异](TODO.md)、[Raycast](https://manual.raycast.com/quicklinks) |
| SNIP-01 | 文字片段、富文本、缩写与动态字段 | 部分实现 | 应用兼容性、中文输入法、Secure Input 与字段语法对照 | [片段](SNIPPETS.md)、[Raycast](https://manual.raycast.com/snippets) |

## 系统、工具和窗口

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| TOOL-01 | Apple 快捷指令发现、运行、别名及热键 | 部分实现 | 实际指令执行、授权撤销、图标刷新及输入输出边界 | [细项](TODO.md)、[实现](../Sources/Keylane/NativeUtilities.swift) |
| TOOL-02 | 计算器、单位和汇率换算 | 部分实现 | 核对自然语言、金融与更多函数/数据能力 | [换算](CALCULATOR-CONVERSIONS.md)、[对照](CALCULATOR-PARITY.md)、[Raycast](https://manual.raycast.com/calculator) |
| TOOL-03 | 系统词典查询 | 部分实现 | 启用词库差异、真实按键与字典跳转 | [细项](TODO.md) |
| TOOL-04 | Emoji 与符号搜索、常用、复制/粘贴 | 部分实现 | 实体按键、组合字符和跨应用粘贴验收 | [细项](TODO.md)、[Raycast](https://manual.raycast.com/emoji-symbols) |
| TOOL-05 | 脚本命令发现、参数、输出、取消与超时 | 部分实现 | 编译 AppleScript、Inline 调度、备用命令与环境差异 | [脚本](SCRIPT-COMMANDS.md)、[差异](TODO.md)、[Raycast](https://manual.raycast.com/script-commands) |
| TOOL-06 | Run 独立快速运行能力 | 待核对 | 单独调查，现有脚本执行不直接代表覆盖 Run | [Raycast Run](https://manual.raycast.com/run) |
| TOOL-07 | 系统动作与系统设置入口 | 部分实现 | 对照完整命令目录，逐项核对系统版本和硬件限制 | [动作](SYSTEM-ACTIONS.md)、[设置](SYSTEM-SETTINGS.md)、[Raycast](https://manual.raycast.com/system-commands) |
| TOOL-08 | 应用自身命令、相机、更新日志 | 已实现 | 摄像头/跨设备相机与相关权限安装版验收 | [应用工具](APP-UTILITIES.md) |
| WIN-01 | 切换窗口、搜索当前应用菜单 | 部分实现 | 全屏、多显示器、Spaces 与不可访问菜单 | [导航](NAVIGATION.md)、[Raycast](https://manual.raycast.com/navigation) |
| WIN-02 | 分屏、跨屏、网格、间距和恢复 | 部分实现 | 实体多显示器、窗口最小尺寸和系统差异 | [窗口管理](WINDOW-MANAGEMENT.md)、[Raycast](https://manual.raycast.com/window-management) |
| WIN-03 | 自定义窗口命令、布局编辑及保存 | 部分实现 | 应用匹配、启动参数、恢复及布局导入格式对照 | [窗口管理](WINDOW-MANAGEMENT.md) |
| FOCUS-01 | 专注会话、应用/网站分类与临时放行 | 部分实现 | 浏览器真实权限、版本兼容及恢复记录实机验收 | [Focus](FOCUS.md)、[Raycast](https://manual.raycast.com/focus) |
| FOCUS-02 | 系统专注过滤条件联动 | 部分实现 | 设置中的入口与真实系统触发待验证 | [Focus](FOCUS.md) |
| FOCUS-03 | Focus 的 AI、Shortcuts 动作和 deeplink | 未实现 | 模块说明明确尚未接入，逐项定义入口与确认行为 | [Focus 边界](FOCUS.md) |
| GAME-01 | Games | 待核对 | 先列出参考游戏与命令，再决定实施批次 | [Raycast Games](https://manual.raycast.com/games) |
| GAME-02 | Typing Practice | 待确认范围 | 此前用户明确排除，保留记录，开发前确认是否重新纳入 | [历史决定](TODO.md) |

## AI、翻译与听写

聊天、工具、上下文、提供商和扩展 API 的支持分别记录。内置模块工具可运行时，仍需单独确认第三方扩展工具和 MCP。

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| AI-01 | Quick AI、备用查询与聊天切换 | 部分实现 | 根搜索及全局热键、共享草稿、实际模型错误和取消验收 | [AI Chat](AI-CHAT.md)、[参考](https://manual.raycast.com/ai/quick-ai) |
| AI-02 | AI Chat、历史、分支、归档、搜索与导出 | 部分实现 | 按最新界面和运行层逐项核对，持续验证旧会话恢复 | [聊天清单](AI-CHAT-REFERENCE-CHECKLIST.md)、[参考](https://manual.raycast.com/ai/ai-chat) |
| AI-03 | 项目、指令、会话归组与附件目录 | 部分实现 | 项目跨会话上下文、自动归档和工作目录语义待对照 | [聊天清单](AI-CHAT-REFERENCE-CHECKLIST.md)、[参考](https://manual.raycast.com/ai/projects) |
| AI-04 | 附件、选中文字、日历及截图文字上下文 | 部分实现 | 统一上下文发现、来源权限与迟到结果处理；关注 PR #212 | [聊天清单](AI-CHAT-REFERENCE-CHECKLIST.md)、[在途 PR](https://github.com/Acckion/Keylane/pull/212) |
| AI-05 | Screen Awareness 的窗口/区域/整屏视觉上下文 | 未实现 | 当前截图文字为手动图片 OCR，完整屏幕感知仍待接入 | [聊天清单](AI-CHAT-REFERENCE-CHECKLIST.md)、[参考](https://manual.raycast.com/ai/screen-awareness) |
| AI-06 | AI 润色、摘要及自定义文本命令 | 部分实现 | 选区、输出替换、模型切换和命令导入完整验收 | [实现](../Sources/Keylane/AITextCommandLauncher.swift)、[参考](https://manual.raycast.com/ai/ai-commands) |
| AI-07 | 模型、API Key、自定义提供方和 YAML | 部分实现 | 特殊云资源和多凭据提供方的一键配置仍有缺口 | [提供方](AI-PROVIDERS.md)、[参考](https://manual.raycast.com/ai/custom-providers) |
| AI-08 | 自动发现/缓存模型、失效恢复与任务路由 | 已实现 | 真实账户和各服务商差异继续验收 | [模型目录](AI-PROVIDER-CATALOG.md) |
| AI-09 | 本地模型 | 部分实现 | 已有 Ollama 等连接方式，模型能力与工具协议逐项核对 | [提供方](AI-PROVIDERS.md)、[参考](https://manual.raycast.com/ai/local-models) |
| AI-10 | ChatGPT / Claude 订阅接入 | 部分实现 | 账户变化、CLI 版本、授权与实际使用量验收 | [提供方](AI-PROVIDERS.md)、[参考](https://manual.raycast.com/ai/bring-your-own-subscription) |
| AI-11 | 内置工具调用、结果展示与确认 | 部分实现 | 各模型协议及只读/有副作用工具的运行闭环 | [共享架构](AI-CONVERSATION-ARCHITECTURE.md)、[工具实现](../Sources/Keylane/AIBuiltinTools.swift) |
| AI-11-a | 共用会话按模块选择工具能力 | 待合并 | 草稿 #226 在已合入 #215/#217/#223/#224 的 dev `37dac2e` 上收敛增量；目录按选择过滤，发送前冻结、选择改变取消审批，真实模型及安装版待验收 | [PR #226](https://github.com/Acckion/Keylane/pull/226)、[契约](AI-CAPABILITY-CONTRACT.md) |
| AI-12 | 各模块统一 AI 动作、文件与剪贴板入口 | 部分实现 | 当前模块样板继续扩展，其他来源见在途 PR | [模块 AI](AI-MODULE-ACTIONS.md)、[参考](https://manual.raycast.com/ai/ai-extensions) |
| AI-12-a | 聊天中的剪贴板与文件搜索引用工具 | 待合并 | PR #217 同步 dev `fc44e8b`；按路径与按引用协议分离，逐次确认，运行内/五分钟引用及来源校验；403+5 项 Swift、合成文件工具/会话、即时排除及发送前撤销回归通过，真实服务未验收 | [PR #217](https://github.com/Acckion/Keylane/pull/217)、[验证](AI-READ-TOOLS-VALIDATION.md) |
| AI-13 | 通用文件读写、目录操作等基础工具 | 部分实现 | #215 已合入 dev `9a51fd9`；仅根内一级不覆盖创建，目录移动后的不确定结果有合成回归；实机/真实提供商待验收 | [PR #215](https://github.com/Acckion/Keylane/pull/215) |
| AI-13-a | 文件工具 PDF、私有结果续读与索引衔接 | 已实现 | #224 已合入，逐页确认与 #217 搜索引用分开保留；真实提供商及安装版待验收 | [PR #224](https://github.com/Acckion/Keylane/pull/224)、[合成验证](AI-FILE-READING.md) |
| AI-13-b | Office、显式本机 OCR 与 Grep 正则 | 已实现 | DOCX/XLSX/PPTX 共用读取层；授权根 PDF 可显式 OCR；正则可选，旧 Office 格式及安装版待验收 | [PR #228](https://github.com/Acckion/Keylane/pull/228)、[实现与验证边界](AI-FILE-READ-ENHANCEMENTS.md) |
| AI-13-c | 文件编辑、移动、废纸篓与恢复 | 待合并 | 普通文件、授权根一级、逐次审批与持久恢复；审查修复原始备份选择、满额恢复记账及移动后撤权恢复身份；外部竞态不宣称版本原子比较；真实废纸篓、外部卷及安装版待验收 | [PR #236](https://github.com/Acckion/Keylane/pull/236)、[架构与边界](AI-FILE-MUTATIONS.md) |
| AI-14 | 片段/备忘录 AI、Emoji 语义推荐 | 待合并 | PR #214 待合并；同步已合入 #212 的 dev，片段模板/成功结果校验、备忘录附加授权与 Emoji 导入关键词已保留；383 项核心与 5 项提供方测试、合成 AI/Emoji/注册表及签名原生窗口回归通过，真实服务未验收 | [PR #214](https://github.com/Acckion/Keylane/pull/214) |
| AI-15 | AI 上下文与命令发现、剪贴板/截图动作 | 待合并 | PR #212 与现有上下文功能合并后逐项更新 | [PR #212](https://github.com/Acckion/Keylane/pull/212) |
| AI-16 | 第三方 AI Extensions 与自动选择工具 | 待核对 | 内置模块适配不等于第三方扩展协议兼容 | [扩展边界](RAYCAST-COMPATIBILITY.md)、[参考](https://manual.raycast.com/ai/ai-extensions) |
| AI-17 | MCP 客户端及 Keylane MCP 服务端 | 待核对 | 两个方向分别调查传输、发现、授权及宿主动作 | [参考](https://manual.raycast.com/ai/model-context-protocol) |
| AI-18 | Skills 发现、加载与执行 | 未实现 | 现有入口说明尚未接入，需实现运行层与权限 | [入口实现](../Sources/Keylane/AIChatCapabilitySection.swift)、[参考](https://manual.raycast.com/ai/skills) |
| AI-19 | Agents 可复用角色与配置 | 待核对 | 区分项目指令与独立 Agent 配置及切换 | [参考](https://manual.raycast.com/ai/agents) |
| AI-20 | 定时/触发式 AI Automations | 待核对 | 调查持久调度、离线、重启、权限和结果通知 | [参考](https://manual.raycast.com/ai/automations) |
| AI-21 | 个性化 Profile 与跨会话 Memory | 待核对 | 分开记录用户主动配置、自动记忆及查看/删除入口 | [参考](https://manual.raycast.com/ai/personalization) |
| AI-22 | 长会话上下文压缩与自动续接 | 待核对 | 单独验证模型上下文边界、摘要和历史一致性 | [参考](https://manual.raycast.com/ai/ai-chat) |
| AI-23 | 双向实时语音对话 | 待核对 | 语音听写已接入；实时语音会话能力另行核对 | [聊天清单](AI-CHAT-REFERENCE-CHECKLIST.md)、[听写](DICTATION.md) |
| AI-24 | 扩展提供的模型与模型能力声明 | 待核对 | 独立核对扩展模型登记、任务能力与宿主路由 | [提供方](AI-PROVIDERS.md)、[参考](https://manual.raycast.com/ai/extension-models) |
| AI-25 | AI 数据、凭据及隐私控制 | 部分实现 | 已有本机凭据与账户范围控制，逐项核对内容保留、删除和云服务政策展示 | [提供方](AI-PROVIDERS.md)、[参考](https://manual.raycast.com/ai/raycast-ai-privacy-security) |
| TRANS-01 | 多服务商翻译、自动翻译与语言切换 | 部分实现 | 实际服务、语言检测、超时与订阅连接验收 | [翻译](TRANSLATOR.md)、[参考](https://manual.raycast.com/translate) |
| TRANS-02 | 自定义语言对命令与替换选中文字 | 部分实现 | 真实目标应用、选区变化及失败反馈 | [翻译](TRANSLATOR.md) |
| DICT-01 | 云端听写、模型配置、历史与重试 | 部分实现（OpenRouter 修复待合并） | 专用转写目录、能力识别与旧缓存补全已补齐；真麦克风、云端服务、跨应用输出和权限仍待验收 | [听写](DICTATION.md)、[参考](https://manual.raycast.com/ai/dictation) |
| DICT-02 | 术语、个性化、按应用/网站样式及统计 | 部分实现 | 实际应用识别、样式匹配和转写质量验收 | [听写](DICTATION.md) |
| DICT-03 | 本地离线听写 | 未实现 | 模块说明明确尚未接入，需确定识别引擎及资源生命周期 | [听写边界](DICTATION.md) |

## 扩展平台

参考 [扩展手册](https://manual.raycast.com/extensions) 和 [开发者 API](https://developers.raycast.com)。逐个公开 API 的进度以 CSV 为准，更新此总表时保留原始证据与状态。

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| EXT-01 | 扩展发现、安装、启用、卸载与生命周期 | 部分实现；目录快照事务已随 #223 合入 | 固定真实扩展样本持续回归；#222 商店与 macOS 运行迁移见 EXT-01-a，安装版待验收 | [兼容范围](RAYCAST-COMPATIBILITY.md) |
| EXT-01-a | 无 VM 的 macOS 扩展构建与运行迁移 | M0／M1首方签名验收通过；完整M1代码待合并 | 签名构建、Darwin依赖、schema2资源收据、受保护安装／更新／恢复完成；受限JSC，原Node仍blocked。M2已开始：无界面命令准入、真实签名 JavaScriptCore 进程与同宿主撤销已验证，签名测试宿主的统一调度和单配置互斥已验证，普通偏好、提示和文本复制的首方能力桥已验证，Launcher 与原生动作已接线，支持显式启用的传统钥匙串签名预览。扩展商店、首次配置确认和安装后命令登记已接线。正式签名配置、公开扩展安装与交互实测，以及跨宿主撤销转发待完成。M3–M5未开始，产品运行仍关闭，性能预算未验收 | [设计](MACOS-EXTENSION-RUNTIME.md)、[M1终审](MACOS-BUILD-M1.md) |
| EXT-02 | no-view / view / menu-bar 三类命令 | 部分实现 | 按命令依赖验证，不能由一个样本推断全生态兼容 | [兼容范围](RAYCAST-COMPATIBILITY.md) |
| EXT-03 | List / Grid / Detail / Form / Actions | 部分实现 | 动态回调、生命周期、资源加载与字段事件逐项推进 | [API 表](RAYCAST-API-COVERAGE.csv)、[说明](RAYCAST-API-COVERAGE.md) |
| EXT-04 | 存储、网络、文件、系统工具和 Utilities | 部分实现 | 用公开契约和隔离运行证据缩小 partial 项 | [API 表](RAYCAST-API-COVERAGE.csv) |
| EXT-05 | 扩展 AI / Tool API | 未实现 | 当前兼容说明列为待覆盖，单独核对授权与执行 | [API 说明](RAYCAST-API-COVERAGE.md) |
| EXT-06 | OAuth 与依赖 OAuth 的命令 | 待确认范围 | 现有兼容目标明确列为例外，保留差异并在开发前确认范围 | [兼容目标](RAYCAST-COMPATIBILITY.md) |
| EXT-07 | 扩展商店、发布、更新与开发工具链 | 待核对 | 分开调查本地开发、市场元数据、分发和版本更新 | [原型](EXTENSION-PROTOTYPE.md)、[开发者文档](https://developers.raycast.com) |

## 同步、发行与长期范围

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| DATA-01 | Keylane 配置导出、预览冲突与恢复 | 部分实现 | 安装版恢复、旧数据和异常中断验收 | [配置迁移](CONFIGURATION-MIGRATION.md) |
| DATA-02 | Raycast 配置迁移 | 部分实现 | 基础配置已有；分类数据扩展见 DATA-02-a（待合并），尚非完整兼容 | [配置迁移](CONFIGURATION-MIGRATION.md)、[分类支持进度](RAYCAST-IMPORT-COVERAGE.md) |
| DATA-02-a | Raycast 分类数据导入、预览与启动恢复 | 待合并 | 片段、文本剪贴板、AI 只读历史/命令、Emoji、专注分类；笔记暂缓，未支持内容不保存；实际导入/重启/撤销待验收 | [PR #219](https://github.com/Acckion/Keylane/pull/219)；补充 12 个强制退出恢复场景及附件轮次回归；[范围及验证](RAYCAST-IMPORT-COVERAGE.md) |
| DATA-02-b | 分类迁移：校验与安装之间的目标占用保护 | 待合并 | 将校验快照中的目标缺失状态传入安装；意外出现的合法库拒绝覆盖并保留恢复记录；实机场景待验收 | [PR #225](https://github.com/Acckion/Keylane/pull/225)、[实现 d27da3f](https://github.com/Acckion/Keylane/commit/d27da3f)、[竞态回归与验证](RAYCAST-IMPORT-COVERAGE.md#校验至安装之间的目标占用竞态) |
| DATA-03 | 跨设备设置、聊天与剪贴板同步 | 待合并 | iCloud Drive 方案 PR #201，合并前不计为已有云同步 | [PR #201](https://github.com/Acckion/Keylane/pull/201)、[Raycast Cloud Sync](https://manual.raycast.com/cloud-sync) |
| DATA-04 | 完整用户数据备份与恢复 | 待核对 | 配置备份之外，核对聊天、历史、附件及冲突恢复范围 | [配置边界](CONFIGURATION-MIGRATION.md)、[原计划](archive/FEATURES.csv) |
| RELEASE-01 | GitHub 更新检查、测试版渠道与更新日志 | 部分实现 | 真实下载/替换/重启、签名迁移和失败恢复验收 | [应用工具](APP-UTILITIES.md)、[发行](CI-RELEASE.md) |
| RELEASE-02 | Developer ID、公证与可信自动更新发行 | 部分实现 | 流程已有实现，实际凭据配置、发行包及端到端更新需独立验证 | [签名](SIGNING.md)、[发行](CI-RELEASE.md) |
| RELEASE-03 | Apple Silicon / Intel 双架构发行 | 待核对 | 当前常用包为 ARM64；Intel 与通用包需分别构建、运行及验收 | [原计划](archive/FEATURES.csv)、[发行](CI-RELEASE.md) |
| PLATFORM-01 | iOS 应用、键盘、Widgets、分享和 Shortcuts | 待确认范围 | 先记录独立移动客户端与桌面功能的依赖，开发批次待定 | [Raycast iOS](https://manual.raycast.com/ios) |
| PLATFORM-02 | Windows 版本 | 待确认范围 | Keylane 当前为 macOS 原生项目，跨平台目标单独确定 | [Raycast 平台说明](https://manual.raycast.com/) |
| PLATFORM-03 | iPhone 镜像应用发现/启动 | 评估中 | PR #109 / #125 为调查与实验，不等同于原生 iOS 客户端 | [PR #109](https://github.com/Acckion/Keylane/pull/109)、[PR #125](https://github.com/Acckion/Keylane/pull/125) |
| TEAM-01 | 组织共享、角色与私有扩展 | 待确认范围 | 此前暂不纳入当前批次，长期目标中保留，开发前确认 | [历史决定](TODO.md)、[Raycast Teams](https://manual.raycast.com/teams) |
| TEAM-02 | 企业 SSO、SCIM、MDM 和管理控制 | 待确认范围 | 调查所需服务、身份及设备管理基础设施，再确定批次 | [Raycast 企业功能目录](https://manual.raycast.com/) |
| SERVICE-01 | 账号、计费与 AI Credits | 待确认范围 | Keylane 当前以用户自己的模型连接为主，商业服务方案另定 | [提供方](AI-PROVIDERS.md)、[Raycast AI Credits](https://manual.raycast.com/ai/ai-credits) |
| EXTRA-01 | 暂存架、内容投放与桌面管理 | 部分实现 | 网格管理、显式关闭空架后保留、搜索中横向选卡待合并；真实 Finder 拖放待验收 | [暂存架](DROP-SHELF.md)、[PR #211](https://github.com/Acckion/Keylane/pull/211) |
| EXTRA-02 | 下载扩展及截图/下载自动入架 | 部分实现；目录子页和截图入架提速待合并 | 真实下载完成识别、首次授权及自动投放安装版验收 | [下载联动](DOWNLOADS-SHELF.md) |

## 下一步执行

1. 开始一个模块前，先核对本表、对应模块文档、最新 dev 和未合并 PR，避免重复开发。
2. 从“部分实现”行的剩余差异拆出可验收任务，引用编号创建 Issue/PR。同一编号的独立子项可追加后缀，例如 `CAL-02-a`。
3. 对“待核对”行先调查官方手册及当前实现，再写清可观察的差异。需要产品决定的默认行为在开发前澄清。
4. 每次合并后，更新受影响的行、关联证据及下方维护记录。一次局部更新只调整已核对行，整表复核时再推进顶部基线。
5. 实机验收注明提交/版本、系统、入口、结果和剩余问题，链接脱敏证据。发布说明引用本次确实交付的条目。
6. 定期复查官方手册目录、新功能和更新日志，补充新能力及参考日期。功能总表、API 覆盖表和模块文档各自保留明确的核对范围。

## 维护记录

| 日期 | 范围 | 基线与证据 |
| --- | --- | --- |
| 2026-11-21 | 建立全仓库总表，纳入 macOS 功能、AI、扩展、同步、平台及长期项目 | dev `9e73f01`；Raycast 官方手册目录及专项页面；仓库模块文档；PR #201/#211/#212/#214/#215 当前均未合并 |
| 2026-11-21 | AI-13-a：新增 PDF 公共提取、请求内结果快照与续读、根内索引查询；保持待合并并记录 #215/#217 依赖 | 原批次基线 dev `2ad472e` + #215 `c87e260`（已被下方按 dev `9a51fd9` 的重整记录取代）；定向与合成验证见 [读取与续读](AI-FILE-READING.md)，无安装版/真实模型验收 |
| 2026-11-21 | DATA-02 / DATA-02-a：扩展 Raycast 分类迁移，独立列出待合并能力与未支持项目；PR #219 审查补充新库原子发布与附件轮次边界修复，12 个强制退出场景及同步 dev `8bacfa8` 后全量 349+3 项 Swift 测试通过，仍待合并 | 实现 `ca498f3`；全量 342 项 Core + 3 项 ProviderConfig、补充 14 项迁移专项、27 项 ReleaseTests、隔离原生流程与签名包校验通过；真实备份仅只读核对，未实机导入 |
| 2026-11-21 | EXTRA-01 暂存架网格审查修复待合并 | [PR #211](https://github.com/Acckion/Keylane/pull/211)，覆盖空架后续裁剪及存档恢复、搜索时横向选择；验收结果见 PR |

| 2026-11-21 | BASE-08：Theme Studio 及设置颜色隔离，标记待合并 | 功能分支 `feat/theme-studio`，[PR #220](https://github.com/Acckion/Keylane/pull/220)，`d414663` / `d8e5c96`；自动化与本机安装证据见 [模块记录](features/THEME-STUDIO.md)，用户最终验收仍待完成 |
维护记录：2026-11-21，BASE-01/BASE-11 搜索模块定向失效与逐条评分复用待合并；330 项 Swift 测试、27 项脚本测试、搜索集成及完整构建通过，实机性能待验收。见 [记录](SEARCH-INVALIDATION.md)。

维护记录：2026-11-21，AI-13 / PR #215 修复 Grep 的 CRLF 换行识别；使用文件后部匹配及混合换行合成样本回归；23 项定向 Swift 测试、27 项脚本测试通过，未安装验收。
| 2026-11-21 | BASE-08：修复紧凑自定义主题连成整块背景的审查问题 | [PR #220](https://github.com/Acckion/Keylane/pull/220)；原生窗口透明像素、独立表面、点击、减少透明度和展开渐显回归；旧行为对照能复现失败 |

维护记录：2026-11-21，BASE-03 页面 ActionSnapshot 公共契约及词典/文件/Emoji/表单样板、替代 Return 与页面会话作用域见 [PR #221](https://github.com/Acckion/Keylane/pull/221)（20a170c），待合并、未安装；完整构建、动作/会话、文件与 Emoji 隔离回归通过；见 [页面动作契约](PAGE-ACTION-CONTRACT.md)。

维护记录：2026-11-21，AI-13-a / PR #224 修复索引根目录 `.` 的披露验证及续读错误提前消费游标；新增失败后重试、满额替换与根目录分页回归，47 项定向 Swift 测试通过。
维护记录：2026-11-21，DATA-02-b：从 dev `8b2fa648` 独立提交 SQLite 安装预期状态修复，原 #219 的实现不重复携带。旧逻辑在隔离合成库中确定性复现覆盖；补丁不改变附件轮次处理；实现 `d27da3f`，独立补丁 [PR #225](https://github.com/Acckion/Keylane/pull/225) 已同步 dev `2ad472e`，全量 356+3 项 Swift、18 项迁移专项、12 个强制退出场景和 27 项 ReleaseTests 通过。验证结果见 [分类支持进度](RAYCAST-IMPORT-COVERAGE.md)。

维护记录：2026-11-21，AI-13 / PR #215 同步 dev `d99d1d9`，澄清仅不覆盖创建、授权目录对象身份与移动后结果不确定的边界；补测提交前拒绝、发布前后移动、目标竞争和不支持系统调用；28 项定向 Swift、6 组集成、27 项脚本测试通过，无真实模型/用户资料/安装验收。

维护记录：2026-11-21，AI-13 / AI-13-a：确认 #215 已合入 dev `9a51fd9`，#224 重整为 PDF/结果续读/受限索引增量；保留 #215 目录身份、不覆盖及结果不确定语义，补测续读取消与创建边界，54 项定向 Swift / 8 组隔离集成 / 27 项脚本测试通过；#226 的工具命名及待整合点见 [读取与续读](AI-FILE-READING.md)。

维护记录：2026-11-21，AI-13-a / PR #224 同步 dev `426b844`（#212），保留共享 AISettings 装配及 #215 最终创建范围；补强每页独立审批、拒绝后重试与审批期间撤权的合成回归，54 项定向 Swift、8 组文件工具集成、27 项脚本测试通过。准确整合提交与 CI 见 PR，不代表安装版或真实模型验收。
维护记录：2026-11-21，AI-14 / PR #214 同步 dev `426b844`（#212 已合入），剔除已进入基线的等价改动，仅保留片段、备忘录、Emoji 及必要公共结果支持；保留 Emoji 导入关键词共用加载和附件来源/权限代次检查。383 项核心 + 5 项提供方、27 项发行保障及合成 AI/Emoji/注册表/签名原生窗口回归通过，结果见 PR；不访问真实备忘录、模型或用户文件，未安装、未合并、未发布。

维护记录：2026-11-21，AI-13-a / PR #224 在验证期间跟随 dev 更新到 `886dcda`；仅保留已合入 #214 的源码与进度记录并解决总表冲突，不修改其他功能分支。此前 `e7f5821` 在 `426b844` 上的 Checks 已通过，新整合提交另行复验。

维护记录：2026-11-21，BASE-01/BASE-11 搜索模块定向失效与逐条评分复用已随 #218 合入 dev；330 项 Swift 测试、27 项脚本测试、搜索集成及完整构建通过，实机性能待验收。见 [记录](SEARCH-INVALIDATION.md)。

维护记录：2026-11-21，EXT-01/BASE-11 第三批 [PR #223](https://github.com/Acckion/Keylane/pull/223)（b55cca4，草稿）目录快照与运行激活分层，动态声明插入/替换/卸载及验证失败保留旧目录开发完成，待合并及安装版验收。前序 #218、#221，见 [目录事务](CATALOG-TRANSACTIONS.md)。

维护记录：2026-11-21，EXT-01 / PR #223 在 dev `fc44e8b` 上修复生命周期期间注册事件丢失的 P2，保留防重入并协调瞬时撤权、服务清理和最终状态；403 项 Swift、27 项脚本及目录集成通过。仍待合并，非安装版验收；见 [目录事务审查记录](CATALOG-TRANSACTIONS.md)。
维护记录：2026-11-21，AI-12-a / PR #217 同步 dev `fc44e8b`，去除 #212/#214 等价差异，保留已合入 #224 的 PDF/续读/受限索引工具。搜索引用使用独立名称和请求/五分钟有效期；补测暂停索引后即时排除目录的元数据隔离。#224/#226 分支未改，未访问真实文件、剪贴板或模型，未安装/合并/发布。

维护记录：2026-11-21，EXT-01 / PR #223 整合 dev `7f6a01b`（#217），保留 AI 工具运行域引用和功能代次快照，以及目录替换／卸载／重新启用的激活撤销；新增合成工具租约回归，验证结果见目录事务记录。仍待合并及安装版验收。

维护记录：2026-11-21，EXT-01-a / BASE-11：基于 dev `37dac2e` 与 #222 `c7b4197` 形成无 VM 的 macOS 扩展体系设计；区分 OS 沙箱可行性、模块生命周期、资源预算与兼容性，列出 M0–M5 迁移门槛。本次仅文档，未修改 #222/运行器、未实测或安装。

维护记录：2026-11-21，EXT-01-a / BASE-11：M0 首方 Apple Development 签名 helper/Node 探针生成 blocked 报告，保留共享容器与进程树失败；清理探针后代并记录未覆盖项。未接通第三方执行、未删除 VM，M1 暂不进入；验证与复验命令见设计第12节。

维护记录：2026-11-21，EXT-01-a / BASE-11 第二批 M0：固定签名槽位与posix_spawn候选完成合成实测，保留旧失败基线；新增用例确认跨槽位文件拒绝、FD关闭和普通组退出，但槽位复用残留、进程准入和detached逃离仍blocked。用户已确认继续严格隔离目标；不转受信模式、不恢复VM、不进入M1，见设计第13节。
维护记录：2026-11-21，DICT-01：`fix/openrouter-dictation`（实现 `a8ecc59`）补齐 OpenRouter 专用转写目录、能力元数据、旧缓存自动刷新与 JSON 音频上传，待合并。404 项 Swift、27 项发布脚本、听写及共享 AI 集成、arm64 Release 构建与 Apple Development 签名包校验通过，尚未安装；公开目录经共享运行时和选择器确认 30 个转写模型，未读取用户密钥或发送用户录音；验证边界见 [听写](DICTATION.md)。

维护记录：2026-11-21，EXT-01-a / BASE-11 第三批 M0：在dev `036cfd7` 上新增第一方受限JS对照，18项子检查通过，整体incomplete；记录启动约束与EOF监督正/负对照和Node兼容差异，不修改API覆盖计数、产品引擎或#222。保持严格隔离，M1未开始，见 [第三批记录](RESTRICTED-JS-M0.md)。

### 2026-11-21 图标与设置分组补齐（本分支）

涉及 BASE-03、BASE-06、BASE-08、APP-02、CLIP-01、SHOT-01、CAL-01、CONTACT-01、NOTE-01、LINK-01、TOOL-01、TOOL-02、TOOL-07、TOOL-08、AI-06、DICT-01、DICT-02、EXTRA-02。AI 设置移入内置扩展首位，补充下载与主题入口，并按命令用途区分图片。图标资源、映射、验证和后续预备资源登记于 [美术资源](ARTWORK.md)。安装版验收随该功能 PR 跟进。

维护记录：2026-11-21，AI-13-b / [PR #228](https://github.com/Acckion/Keylane/pull/228)，实现 `9e0c43e`：从 dev `37dac2e` 新建读取增强分支，Office/本机显式 OCR/行级正则共用现有授权、接收方确认与私有续读；保留 #215/#217/#224 行为，414+3 项全量、最终 12 项增强及文本框审查修复后的 66 项定向复验、9 组基础文件集成、签名隔离引用测试及 27 项发行保障检查通过；准确提交与 Checks 见 PR，未安装或调用真实模型。

维护记录：2026-11-22，EXT-01-a / BASE-11 第四批 M0：基于 dev `5c6d6aa4` 新增最小有界broker，17项签名双进程子检查通过；根仍为合成安装记录，不冒充Store收据验证。补测读／写撤权阶段、重放、限额和进程退出，整体incomplete；保留旧Node阻塞和严格隔离目标，未接产品运行器、未进入M1。见 [第四批记录](BROKER-M0.md)。

维护记录：2026-11-22，EXT-01-a / BASE-11 第五批 M0：修复截断头被当成正常EOF、截断回复后继续使用通道的缺口；新增19项首方签名异常传输／有界内存子检查及4项CI测试。17项broker与18项受限JS复测通过子集，整体仍incomplete。只读核对#222真实收据准入边界，未接产品、未进入M1；本分支待合并，见 [第五批记录](TRANSPORT-PRESSURE-M0.md)。

维护记录：2026-11-22，EXT-01-a / BASE-11 第六批M0（前序 `ea1980b6`）：原样编译#222 `c7b4197` 收据／注册表算法，20项签名首方制品及撤权子检查通过；禁用／替换须先确认旧helper退出，CAS失败不能恢复旧lease。修复内存采样退出竞态并保留存活观测失败拒绝，整体incomplete；本分支待合并，产品未接通、M1未开始，见 [第六批记录](RECEIPT-BRIDGE-M0.md)。

维护记录：2026-11-21，AI-11-a / 草稿 #226 以已合入依赖的 dev `37dac2e` 重整，移除依赖等价差异；保留 `keylane_read_searched_file`、路径授权、PDF/分页及目录生命周期边界，仅新增会话模块能力选择与发送前冻结。隔离验证与精确头 CI 见原 PR，不安装/合并/发布。


维护记录：2026-11-21，AI-13-c：用户明确本批包含直接编辑原件、移动与废纸篓；从 dev `37dac2e` 独立实现，保留旧不覆盖创建接口和逐次确认，新修改使用原生协调、版本检查、持久快照及不确定状态。实现 `3a04fde`，验证及 [PR #236](https://github.com/Acckion/Keylane/pull/236) 见下方与模块文档，未安装或访问用户资料。

维护记录：2026-11-21，AI-13-c 在工作期间同步 dev `01cee5a`（#228/#230 已合入），保留 Office/OCR/正则、OpenRouter 听写和现有审批结构；新增文件操作仍为独立增量，整合后的验证另行记录。

维护记录：2026-11-21，AI-13-c / PR #236 在 dev `e23edf81` 上完成整合；保留 #233 已验收图标。全量436+3、最终78项定向及完整应用构建、10组文件工具集成、签名隔离引用/附件及28项发行保障检查通过；真实废纸篓、用户资料、外部卷和提供方未验收，未安装/合并/发布。

维护记录：2026-11-23，EXT-01-a / BASE-11，前序 `c0a8ecb1`：同步dev `d6a3074c` 保留#226/#236；用户明确改用受限JSC候选。M0统一首方可行性验收通过，原Node复验仍blocked，兼容差异不改CSV计数。8组证据及后续阶段边界见 [M0终审](M0-ACCEPTANCE.md)；本分支待合并，未安装、未启动第三方或进入M1。
维护记录：2026-11-21，EXTRA-02 文件夹观察设置与普通截图自动入架提速，见 [下载与暂存架联动](DOWNLOADS-SHELF.md)。

维护记录：2026-11-23，EXT-01-a / BASE-11，前序 `4fd73ff1`：M1第一批在新分支整合当前dev `b09c5dd`（#231），新增有界构建数据契约／固定配方／结果资源摘要和取消协调；17项真实签名首方构建检查通过，整体M1仍incomplete，正式profile、#222适配与安装事务未交付，见 [M1记录](MACOS-BUILD-M1.md)。未安装／推送／修改#222，M2–M5未开始。

维护记录：2026-11-23，EXT-01-a / BASE-11，前序 `00a23eba`：完整M1复用#222 `c7b4197` 的纯Core底座，接通真实签名构建／新profile保护／Darwin依赖／schema2资源收据和统一安装器；修复候选更新、禁用快照、卸载候选清理及head提交发布恢复。553项Swift、72项Python、两组43项首方签名观察及Apple Development签名ARM64 DMG通过，详见 [M1终审](MACOS-BUILD-M1.md)。待合并，未安装/推送/发布，M2–M5未开始；没有恢复VM、启用运行或改API统计。
维护记录：2026-11-23，FILE-01：实机发现增量扫描结束后反复全表统计。改用事务内增删／类型变化触发计数，旧索引首次打开初始化一次，后续读取单行汇总。451 项 Swift 测试及真实文件事件集成通过，覆盖旧索引、多连接、回滚和动态更新；Apple Development 签名安装已完成，后台 CPU 与长期能耗正在复验。

维护记录：2026-11-23，EXT-01-a 完整M1提交 `71e4e3e8`，随后以 `f79d081d` 整合dev `5b4378ce` 的#238/#237/#240。保留索引能耗和真实打包产物路径修复；556项Swift、72项Python与43项签名首方观察通过，运行仍关闭，见 [整合复验](MACOS-BUILD-M1.md#最新dev整合复验)。

维护记录：2026-11-23，EXT-01-a / PR #241，前序 `732c64f4`：新增来源攻击实测推翻旧ACL方案，改为Data Protection Keychain v2与已授权的准确应用访问组，拒绝采用旧记录及无权限宿主。48项真实签名观察、558项Swift、80项Python和Apple Development ARM64包通过；同时修复嵌套发行时间戳、无证书隔离打包（无扩展组合）及生命周期变化残留候选。详见 [来源修复与PR验收](MACOS-BUILD-M1.md#配置来源补测与pr-241修复)。仅首方测试宿主使用现有匹配描述文件，普通Keylane仍缺配置仅浏览；待合并，未安装／合并／发布。

维护记录：2026-11-23，PR #241 来源修复 `82dff3d1` 后整合dev `99c7a373`（#239），整合提交 `80e98416`；无Swift／签名组合实现变化，元数据提取和CI脚本增量的80项Python及最终Apple Development包验证通过。

维护记录：2026-11-23，PR #241 CI失败定位为手动Core编译缺少包名。18个全量Core集成脚本统一包名而不放宽package可见性，CI同款AI文件工具脚本10组本机临时数据测试通过；产品源码与签名包字节未变，远端Checks按新头重新运行。

维护记录：2026-11-23，EXT-01-a / M2 从 PR #241 的已验证提交 `7b1c4639` 开始。复用受保护注册表与签名收据，在注册表锁内为无界面命令签发一次性票据。定向回归验证单运行槽、停用时撤销、等待驱动退出及重启用后拒绝旧代次。测试驱动模拟退出延迟，真实签名运行器、跨宿主协调及能力代理仍待交付。

维护记录：2026-11-23，EXT-01-a / M2 前序 `499c613c`。真实签名运行器与共用进程监督通过 10 项首方检查，含运行中停用及旧代次拒绝，M1 签名组合回归通过。阶段仍未完成，见 [运行证据](evidence/macos-runtime-m2/native-no-view.json)。

维护记录：2026-11-23，EXT-01-a / M2 前序 `01d63f94`。签名配置绑定运行辅助程序，共用安装服务调度。验证同一配置竞争拒绝、宿主终止和辅助程序退出后的接管。仍待普通应用接入与能力代理。

维护记录：2026-11-23，EXT-01-a / M2 前序 `801f46a2`。按收据授权绑定普通偏好，提示与文本复制在成功退出后由宿主复核票据再提交，18 项签名观察通过。输出在首方宿主捕获，M2 整体待验收。

维护记录：2026-11-23，EXT-01-a / M2 前序 `19ecc25`。已验证的运行配置接入 Launcher 模块与现有原生反馈／复制。签名首方夹具验证旧 Launcher 代次拒绝。普通产品交互仍待正式签名与商店配置。

维护记录：2026-11-23，EXT-01-a / M2 前序 `f71e859d`。正式打包与测试宿主共用签名入口，验证证书、描述文件、准确应用 ID 及助手摘要。测试宿主运行验证与默认签名包通过，测试描述文件无法为正式应用生成运行包。当前 Mac 缺少正式应用匹配的描述文件，正式验收未完成。

维护记录：2026-11-23，EXT-01-a / M2 基于 `0f0a0ec8` 增加显式启用的传统钥匙串开发签名预览。正式包仍要求专属访问组授权。预览使用独立服务名，关闭该选项后需重新登记正式配置。81 项 Python 检查、561 项核心 Swift 测试及 3 项提供方配置测试通过。两种钥匙串方案的签名首方宿主分别通过 7 项运行观察，预览 ARM64 DMG 的 Apple Development 签名与包内容校验通过。商店与正式安装版第三方扩展交互验收仍待完成。见 [运行设计](MACOS-EXTENSION-RUNTIME.md#m2-传统钥匙串预览)。

维护记录：2026-11-23，EXT-01-a / M2 接通 Launcher 扩展商店、首次运行配置及安装状态到 Launcher 模块目录的更新。102 项 M2 和 Store 定向 Swift 测试通过，传统钥匙串签名测试宿主的 7 项观察通过，ARM64 Apple Development 调试预览 DMG 校验通过。真实商店扩展的下载、安装、运行与重启复验仍待完成。

维护记录：2026-11-23，EXT-01-a / M2，商店预览安装版已确认能加载 Raycast 官方目录，且 UUID Generator 因当前运行兼容限制未进入安装。仅含不支持命令的制品现在会在构建前拒绝。102 项定向 Swift 测试通过。传统钥匙串 Apple Development 签名首方样板通过 12 项观察，覆盖登记、构建安装、运行、新进程重开后再运行、停用及启用、卸载以及重启后确认清除。首方样板走真实安装协调器和签名 JavaScriptCore 进程，公开目录中符合当前兼容子集的第三方扩展成功运行仍待实机核验。

维护记录：2026-11-23，EXT-01-a / M2 修复预览升级后旧配置绑定不同构建摘要而反复重试的问题。对明确的构建摘要冲突提供重新配置入口，只在新配置成功打开后切换并记录旧选择，保留旧钥匙串记录和扩展目录。102 项定向 Swift 测试、Apple Development 签名安装包校验及本机启动通过，实机已看到重新配置的确认提示，等待用户确认创建。

维护记录：2026-11-23，EXT-01-a / M2 接通官方 UUID Generator 固定修订 `886cbd73fe377ad1d8f0c17083e6cd4c96748a33` 的 Format UUID。只接入该命令所用的偏好读取、文本复制和反馈，复用宿主能力票据，正式安装收据只登记这条命令。签名测试宿主以真实官方源码通过安装、运行、重启后运行和卸载，核对复制内容与提示效果，未写入用户剪贴板。15 项签名商店观察、21 项签名运行器观察和 102 项定向 Swift 测试通过。

维护记录：2026-11-23，EXT-01-a / M2，共用审核表接入固定修订的 Format UUID 和 Silent Mention / Copy Zero Width Space。商店、构建、签名和启动器从同一份记录读取已审核命令，兼容层共用复制和旧版提示调用。两款官方源码用同一签名宿主通过 16 项观察，包含安装、运行和卸载，UUID 另有重启回归。测试捕获复制效果，无实际剪贴板写入。102 项定向 Swift 测试通过。此批未安装到本机。

维护记录：2026-11-23，EXT-01-a / M2，固定版本 Lorem Ipsum 的 Generate Markdown 加入共用审核表，限定复制输出。受控关闭窗口支持清空根查询，仅在用户仍处于启动命令时的页面上下文时应用。签名测试宿主验证官方源码和锁定 npm 依赖的构建、安装、运行和卸载，同时捕获关闭、复制 Markdown 和成功提示，未修改真实窗口或剪贴板。Format UUID、Silent Mention 同轮回归通过，共 17 项签名观察。102 项定向 Swift 测试通过，本批未安装到本机。

维护记录：2026-11-24，EXT-01-a / M2 扩展 Lorem Ipsum 的固定版本兼容范围，新增 HTML、段落、句子和单词生成。数量参数可省略，旧 Markdown 安装收据仍可验证。使用已下载的官方源文件和锁定依赖，通过 esbuild 与 JavaScriptCore 验证五条命令的八种调用。102 项定向 Swift 测试通过。签名商店验收在 GitHub 下载限流处停止，未替换本机安装版。

维护记录：2026-11-24，EXT-01-a / M2，UUID Generator 新增 Pack TypeID 和 Parse TypeID，宿主支持按名称传递多个参数，JavaScriptCore 提供纯 UTF‑8 编码。旧版单命令安装收据继续可验证。正式下载路径的临时签名验收通过，覆盖 UUID Generator 三条命令的安装、运行、重启及卸载，Silent Mention 与 Lorem Ipsum 五条命令同轮通过。17 项签名观察、102 项定向 Swift 测试通过。

维护记录：2026-11-24，EXT-01-a / M2 迁移旧运行器的 Icon、Color、Image.Mask、Keyboard.Shortcut.Common 和 LaunchType 常量。比对旧、新导出对象的值，验证 JavaScriptCore 实际导入及前台启动参数。102 项定向 Swift 测试和 17 项签名验收通过，签名宿主覆盖 UUID Generator 三条、Silent Mention 两条和 Lorem Ipsum 五条命令。本批尚未安装到 Mac。

维护记录：2026-11-24，EXT-01-a / M2 迁移前台无界面命令的 environment。作者、扩展名和入口名来自已验证命令标识，并提供旧命令名、模式别名。canAccess 检查当前调用是否获得复制、反馈或关闭窗口能力。JavaScriptCore 验证字段、授权判断和无效元数据拒绝，102 项定向 Swift 测试和 17 项签名宿主观察通过，覆盖三款官方扩展十条命令。本批未安装到本机。

维护记录：2026-11-24，EXT-01-a / M2，启动器与商店执行入口向扩展传递外观和字号快照，恢复 environment.appearance、theme 和 textSize。跟随系统模式使用窗口实际外观，保留旧适配的字号映射，小和标准映射 medium，大映射 large。正式构建、102 项定向 Swift 测试、21 项签名运行器检查通过，其中异步命令验证收到冻结的外观和字号。未安装到本机。

维护记录：2026-11-24，EXT-01-a / M2 迁移 clearSearchBar 与 popToRoot，保留可选滚动到顶部及可选清空查询行为。两项能力分别授权，有效作用域在提交整批效果前复核。102 项 Swift 定向测试及 21 项签名运行器检查通过，包含异步命令的导航效果顺序和未授权拒绝。商店命令尚未启用这两项能力，本批未安装到本机。

维护记录：2026-11-24，EXT-01-a / M2 将旧版 `specialKeys` 及其 16 个键名迁移到 JavaScriptCore。测试命令从兼容模块导入对象，逐项比对旧运行器的键名和值并验证对象冻结。102 项 Swift 定向测试通过。此批待合并，安装版和商店扩展兼容数量待核对。

维护记录：2026-11-24，EXT-01-a / M2 新增 16 项旧兼容清单条目：Alert 动作样式族 6 项、PopToRootType 常量族 4 项、@raycast/utils 链接构造族 6 项。以默认 Raycast URL 格式生成链接。运行器测试导入两个包，对照旧实现的常量和链接输出，覆盖中文、保留字符和有序参数。102 项 Swift 定向测试通过。待合并，安装版待验收；弹窗、导航行为和链接打开均沿用现有宿主能力范围。

维护记录：2026-11-25，EXT-01-a / M2，在独立工作树迁移或补齐 37 项旧兼容清单条目：提示反馈 10 项、纯工具和随机 ID 5 项、Cache 10 项、窗口关闭模式 1 项、LocalStorage 11 项。定向运行验证覆盖 Toast 更新与隐藏、两类存储授权、导航模式和工具输出。现有商店命令授权保持原样，待合并与安装版验收。

维护记录：2026-11-25，EXT-01-a / 非 OAuth 接入第 00 批。固定 1,007 项非 OAuth 基线，统一审核命令的构建、清单与收据授权校验；用 Apple Development 签名临时宿主复验三款真实扩展十条命令构建、安装、运行、新进程重新运行及卸载。19 项签名商店观察、21 项签名运行器观察、108 项 Swift 定向测试和 81 项发布脚本测试通过。待合并，未替换本机安装版。见 [第 00 批验收](MACOS-RAYCAST-API-PLAN.md#第-00-批验收记录)。

维护记录：2026-11-25，EXT-01-a / 非 OAuth 接入第 01 批。补齐环境宿主版本和当前授权判断。在真实打包接口上验证 579 项导出及成员，其中 478 个图标值逐项对照固定官方 SDK。23 项签名运行器、19 项签名商店、108 项相关 Swift 和 81 项发布脚本测试通过。待合并，未替换本机安装版。见 [第 01 批验收](MACOS-RAYCAST-API-PLAN.md#第-01-批验收记录)。

维护记录：2026-11-25，EXT-01-a / 非 OAuth 接入第 02 批，完成 Cache 与 LocalStorage 的原子双写和旧数据读取、普通偏好与旧元数据、独立授权的设置路由和有限本机诊断。27 项签名运行器、19 项签名商店、109 项 Swift 定向和 81 项发布脚本检查通过。资源与支持目录、缓存目录、敏感偏好和完整诊断仍待接入。待合并，未替换本机安装版。见 [第 02 批验收](MACOS-RAYCAST-API-PLAN.md#第-02-批验收记录)。

维护记录：2026-11-25，EXT-01-a / 非 OAuth 接入第 03 批阶段进展。接通受监督的双向页面帧和修订号事件队列，首方签名样本在同一 JavaScriptCore 进程验证 Detail 数据更新、返回、失效动作和撤权，补齐显式 HUD 返回选项。32 项签名运行器、19 项签名商店、109 项相关 Swift 和 81 项发布脚本检查通过。第 03 批未完成，React 与启动器 UI、动作菜单和交互反馈待接入。见 [第 03 批阶段验收](MACOS-RAYCAST-API-PLAN.md#第-03-批阶段验收记录)。

维护记录：2026-11-25，EXT-01-a / 第 02 批补接制品只读资源和按安装持久保存的支持目录，支持有界同步／Promise 文件读写及原子提交。35 项签名运行器、20 项签名商店、110 项相关 Swift、81 项发布脚本检查通过。Cache 目录、敏感和选择型偏好、完整诊断仍待接入，未替换本机安装版。见 [第 02 批资源与支持目录补验](MACOS-RAYCAST-API-PLAN.md#第-02-批补验资源与支持目录)。

维护记录：2026-11-25，EXT-01-a / 第 02 批补齐 Cache 虚拟目录、授权选择值、受保护密码和本机诊断界面。36 项签名运行器、15 项受保护配置、20 项签名预览商店、115 项 Swift 定向及 81 项发布脚本检查通过。诊断按原生进程指标提供，保留 Raycast JS 堆和远端上报的差异；安装版设置交互待验收。见 [第 02 批 Cache 目录、偏好与诊断](MACOS-RAYCAST-API-PLAN.md#第-02-批补验cache-目录偏好与诊断)。

维护记录：2026-11-25，EXT-01-a / 第 03 批继续验证真实 React 挂载与状态保持，增加静态子菜单、模态选择与 Toast 按钮的有界事件协议。115 项相关 Swift 和 32 项签名运行器检查通过；生产 React 适配、启动器原生交互和商店视图准入仍待实现。见 [第 03 批 React 与反馈](MACOS-RAYCAST-API-PLAN.md#第-03-批补验react-挂载与交互反馈)。

维护记录：2026-11-25，EXT-01-a / 第 03 批生产路径接通。受监督 React Detail 从签名构建和注册表进入 Launcher，复用页面、动作菜单、快捷键与返回，补齐动态菜单、确认及 Toast 双按钮。首方签名试验验证交互、撤权和越权拒绝。三款原有公开扩展的十条命令回归通过。待合并，未替换 Mac 安装版，公开 view 命令和实际原生交互待验收。见 [第 03 批生产路径](MACOS-RAYCAST-API-PLAN.md#第-03-批续验生产-react-路径与启动器)。
