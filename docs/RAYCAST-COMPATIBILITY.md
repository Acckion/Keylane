# Raycast 扩展兼容

目标是在 macOS 版 Keylane 支持 Raycast 公开扩展的 `no-view`、`view` 和 `menu-bar` 命令。OAuth API、OAuth Utilities 及依赖这些登录流程的命令列为例外。同一扩展的其他命令仍按各自依赖验证。平台和服务依赖按命令记录，报告需区分 Keylane API 缺口、第三方服务或账户前提以及 OAuth 例外。文档基线为 2026-11-12 核对的官方目录。 [Raycast API 文档索引](https://developers.raycast.com/llms.txt) · [Manifest](https://developers.raycast.com/information/manifest)

[API 逐项清单与缺口](RAYCAST-API-COVERAGE.md)

| 工作 | 已验证的范围 | 完成条件 |
| --- | --- | --- |
| 扩展设置与数据 | Format UUID 读取默认操作。Generate UUIDs 与 View History 已验证扩展独立的 LocalStorage 和 App 重启恢复。Keylane 支持启停、别名和热键 | 根据 manifest 渲染扩展和命令偏好，校验必填项和默认值。覆盖各字段类型、Keychain 密码、扩展独立的 LocalStorage 和 Cache，并验证跨命令、重启、升级与隔离 |
| 通用运行时和原生界面 | UUID Generator 固定版本的 9 条命令、CHMOD Lookup 和 Work Time Countdown 菜单栏样本。CLI 可读三个命令模式、平台和后台刷新间隔 | 覆盖三个命令模式及后台刷新，按官方 API 验证 React 状态和事件、List、Grid、Form、Detail、Actions、导航、菜单栏、命令调用和参数、deeplink、键盘、窗口与搜索栏。覆盖反馈、剪贴板、环境、系统工具、浏览器、窗口管理、Tool 与 AI 相关公开接口及所需的非 OAuth Utilities。为涉及宿主权限和平台服务的 API 实测授权、取消与失败 |
| 第三方安装、更新与发布 | 已审阅镜像可在签名开发预览安装、原子替换和卸载 | 可信来源与依赖锁定、隔离构建、签名校验、更新原子切换和回滚、卸载清理、开发 CLI、发行签名与公证。架构复审覆盖第三方制品、网络、后台执行与公开分发 |
| Store 目录 | 公开仓库目录、按需清单、已加载条目的分类、详情与两个样本的安装入口 | 可复验的数据源、全目录分类、下载量与作者头像、兼容状态、安装和更新进度、限流回退。浏览和目录更新验证不执行扩展代码 |

验收同时记录 API 和固定版本的真实扩展。每个命令记录模式、依赖、构建结果、实际运行结果及异常路径。UUID Generator 已验证偏好和跨命令数据。已接入首个 `menu-bar` 样本，后续扩展菜单栏能力并验证通用有状态界面。扩大样本覆盖后，用同一套检查执行公开目录的批量验证。 [原型与隔离验收](EXTENSION-PROTOTYPE.md) · [Preferences](https://developers.raycast.com/api-reference/preferences) · [Storage](https://developers.raycast.com/api-reference/storage) · [Menu Bar Commands](https://developers.raycast.com/api-reference/menu-bar-commands)
