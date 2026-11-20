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
| BASE-03 | 标准操作面板、菜单搜索与键盘导航 | 部分实现；动作与页面会话迁移待合并 | 所有内置及第三方入口逐项接入公共组件 | 已有验证记录；[架构](LAUNCHER-ARCHITECTURE.md) |
| BASE-04 | 命令别名、热键、启用状态 | 部分实现 | 确认左右修饰键、fn、冲突、IME 与实体键盘支持边界 | [实现](../Sources/Keylane/ShortcutSettingsPreferences.swift)、[细项](TODO.md) |
| BASE-05 | Hyper Key、双击与导航绑定 | 部分实现 | 对照物理键映射、短按及 Secure Input 行为 | 实机待验收；[历史清单](archive/FEATURES.csv) |
| BASE-06 | 设置全文搜索、定位到模块与命令 | 已实现 | 新增设置页持续补搜索关键词与定位锚点 | [设置入口](../Sources/Keylane/Settings.swift) |
| BASE-07 | 共用菜单栏条目与生命周期 | 已实现 | 新模块复用登记、更新、注销和可见性设置 | 已有实机及隔离记录；[菜单栏](MENU-BAR-CALENDAR.md) |
| BASE-08 | 主题与自定义主题导入/共享 | 部分实现 | 已有外观设置；Raycast 自定义主题完整范围待核对 | [设置](../Sources/Keylane/Settings.swift)、[Raycast 主题](https://manual.raycast.com/themes) |
| BASE-09 | 通用动态占位符及修饰符 | 部分实现 | 片段、快捷链接分别支持部分语法，核对共用解析与完整修饰符 | [片段](SNIPPETS.md)、[快捷链接](QUICKLINKS.md)、[参考](https://manual.raycast.com/dynamic-placeholders) |
| BASE-10 | 首次引导、权限、辅助使用与本地化 | 部分实现 | 持续核对默认状态、拒绝/撤销、VoiceOver、对比度和中文输入 | [协作规范](../AGENTS.md)、[架构](LAUNCHER-ARCHITECTURE.md) |
| BASE-11 | 启动/查询性能、内存与后台生命周期 | 部分实现；定向评分复用待合并 | 使用可重复工作负载，分别记录耗时、内存与功能回归 | [历史验证证据](evidence/)、[细项](TODO.md) |

## 应用、文件与个人资料

各行仅记录指定能力。模块级“部分实现”还包含未闭环的使用场景，细项差异沿用 [TODO](TODO.md)。

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| APP-01 | 应用发现、拼音搜索、收藏及刷新 | 部分实现 | 外置/网络卷、扫描深度和失效路径继续验收 | [应用生命周期](APPLICATION-LIFECYCLE.md)、[Raycast](https://manual.raycast.com/applications) |
| APP-02 | 应用正常退出、卸载与残留预览 | 部分实现 | 应用差异、拒绝权限及残留范围逐项验收 | [卸载](UNINSTALL-PREVIEW.md) |
| APP-03 | 按应用闲置自动退出 | 部分实现 | 各应用保存对话框、退出拒绝和重启恢复实测 | [生命周期](APPLICATION-LIFECYCLE.md)、[Raycast](https://manual.raycast.com/auto-quit) |
| FILE-01 | 文件检索、筛选、预览与文件信息 | 部分实现 | 搜索范围、内容索引、排序和大型目录继续对照 | [细项](TODO.md)、[Raycast](https://manual.raycast.com/file-search) |
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
| AI-12 | 各模块统一 AI 动作、文件与剪贴板入口 | 部分实现 | 当前模块样板继续扩展，其他来源见在途 PR | [模块 AI](AI-MODULE-ACTIONS.md)、[参考](https://manual.raycast.com/ai/ai-extensions) |
| AI-13 | 通用文件读写、目录操作等基础工具 | 待合并 | PR #215 尚未合入基线，后续按实际工具逐项验收 | [PR #215](https://github.com/Acckion/Keylane/pull/215) |
| AI-14 | 片段/备忘录 AI、Emoji 语义推荐 | 待合并 | PR #214 尚未合入基线，确认权限和副作用行为 | [PR #214](https://github.com/Acckion/Keylane/pull/214) |
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
| DICT-01 | 云端听写、模型配置、历史与重试 | 部分实现 | 真麦克风、云端服务、跨应用输出和权限验收 | [听写](DICTATION.md)、[参考](https://manual.raycast.com/ai/dictation) |
| DICT-02 | 术语、个性化、按应用/网站样式及统计 | 部分实现 | 实际应用识别、样式匹配和转写质量验收 | [听写](DICTATION.md) |
| DICT-03 | 本地离线听写 | 未实现 | 模块说明明确尚未接入，需确定识别引擎及资源生命周期 | [听写边界](DICTATION.md) |

## 扩展平台

参考 [扩展手册](https://manual.raycast.com/extensions) 和 [开发者 API](https://developers.raycast.com)。逐个公开 API 的进度以 CSV 为准，更新此总表时保留原始证据与状态。

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| EXT-01 | 扩展发现、安装、启用、卸载与生命周期 | 部分实现 | 固定真实扩展样本持续回归，完善失败及权限体验 | [兼容范围](RAYCAST-COMPATIBILITY.md) |
| EXT-02 | no-view / view / menu-bar 三类命令 | 部分实现 | 按命令依赖验证，不能由一个样本推断全生态兼容 | [兼容范围](RAYCAST-COMPATIBILITY.md) |
| EXT-03 | List / Grid / Detail / Form / Actions | 部分实现 | 动态回调、生命周期、资源加载与字段事件逐项推进 | [API 表](RAYCAST-API-COVERAGE.csv)、[说明](RAYCAST-API-COVERAGE.md) |
| EXT-04 | 存储、网络、文件、系统工具和 Utilities | 部分实现 | 用公开契约和隔离运行证据缩小 partial 项 | [API 表](RAYCAST-API-COVERAGE.csv) |
| EXT-05 | 扩展 AI / Tool API | 未实现 | 当前兼容说明列为待覆盖，单独核对授权与执行 | [API 说明](RAYCAST-API-COVERAGE.md) |
| EXT-06 | OAuth 与依赖 OAuth 的命令 | 待确认范围 | 现有兼容目标明确列为例外，保留差异并在开发前确认范围 | [兼容目标](RAYCAST-COMPATIBILITY.md) |
| EXT-07 | 扩展商店、发布、更新与开发工具链 | 待合并 | 商店可浏览；已验证配置入口的短提示只支持展示/更新，不含动作。普通版仍需合格运行资源和配置接入；真机安装、运行和持久化待验证。 | [草稿 #222](https://github.com/Acckion/Keylane/pull/222)、[原型](EXTENSION-PROTOTYPE.md) |

## 同步、发行与长期范围

| 编号 | 能力 | 实现状态 | 剩余差异与下一步 | 验收与证据 |
| --- | --- | --- | --- | --- |
| DATA-01 | Keylane 配置导出、预览冲突与恢复 | 部分实现 | 安装版恢复、旧数据和异常中断验收 | [配置迁移](CONFIGURATION-MIGRATION.md) |
| DATA-02 | Raycast 配置迁移 | 部分实现 | 已支持部分配置格式，按类别明确支持与不支持字段 | [配置迁移](CONFIGURATION-MIGRATION.md) |
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
| EXTRA-02 | 下载扩展及截图/下载自动入架 | 部分实现 | 真实下载完成识别、首次授权及自动投放安装版验收 | [下载联动](DOWNLOADS-SHELF.md) |

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
| 2026-11-21 | EXTRA-01 暂存架网格审查修复待合并 | [PR #211](https://github.com/Acckion/Keylane/pull/211)，覆盖空架后续裁剪及存档恢复、搜索时横向选择；验收结果见 PR |

维护记录：2026-11-21，BASE-01/BASE-11 搜索模块定向失效与逐条评分复用待合并；330 项 Swift 测试、27 项脚本测试、搜索集成及完整构建通过，实机性能待验收。见 [记录](SEARCH-INVALIDATION.md)。


维护记录：2026-11-21，BASE-03 页面 ActionSnapshot 公共契约及词典/文件/Emoji/表单样板、替代 Return 与页面会话作用域见 [PR #221](https://github.com/Acckion/Keylane/pull/221)（20a170c），待合并、未安装；完整构建、动作/会话、文件与 Emoji 隔离回归通过；见 [页面动作契约](PAGE-ACTION-CONTRACT.md)。

维护记录：2026-11-21，EXT-07 草稿 #222 的配置入口可接宿主短提示；权限只缩不增，提示 ID 随当前运行凭据失效。未执行真实扩展、安装或发布。
