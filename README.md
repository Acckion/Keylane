<h1 align="center">Keylane</h1>
<p align="center">想到，即刻开始。完全免费，开源可改。</p>
<p align="center">面向 macOS 的原生键盘启动器，把应用、文件和日常工具放进一个搜索窗口。</p>
<p align="center"><b>简体中文</b> · <a href="README.en.md">English</a></p>
<p align="center"><a href="https://acckion.github.io/Keylane/">官网</a> · <a href="https://github.com/Acckion/Keylane/releases">下载</a> · <a href="https://github.com/Acckion/Keylane/issues">反馈与建议</a></p>

![Keylane 主搜索：在同一个窗口中查找应用和文件](docs/images/launcher.png)

按下 **Option + Space**，输入你要找的应用、文件或命令。用方向键选择，按 **Return** 打开，按 **Escape** 返回或收起窗口。不必在多个应用之间来回切换，常用操作从键盘开始。

## 一个入口，处理日常小事

### 找到应用，也找到文件

支持应用名称、拼音与模糊搜索，常用应用可以收藏。文件搜索结合 Spotlight 与本地索引，支持按类型筛选、查看内容预览和文件信息，并通过操作菜单继续处理文件。

![Keylane 文件搜索：左侧筛选结果，右侧查看文件预览与信息](docs/images/file-search.png)

### 复制过的内容，随时找回来

集中查看文字、图片和文件的剪贴板历史，搜索、筛选、预览或置顶常用内容。选中条目后复制，或粘贴到正在使用的应用；历史保留时间和持久化方式由你设置。

![Keylane 剪贴板历史：搜索复制记录，查看内容和来源](docs/images/clipboard.png)

### 常用工具，不用另开一个应用

- **随手计算**：直接输入算式，查看并复制结果。
- **查词与符号**：查询系统词典，搜索 Emoji 和符号。
- **系统与窗口**：搜索系统设置、执行常用系统操作、切换窗口和调整布局。
- **本机资料**：查看日历、搜索联系人、查找截图与 OCR 文字，连接 Apple 备忘录。
- **自己的工作流**：运行 Apple 快捷指令和脚本，使用快捷链接与文字片段，为命令设置别名和快捷键。
- **配置迁移**：备份与恢复 Keylane 设置，导入 Raycast 配置中支持的基本偏好、命令映射和快捷链接。导入前可预览，不支持项会跳过。

## 完全免费，开源可改

**Keylane 完全免费，没有订阅，也没有付费解锁。** 当前源码采用 [GPL-3.0-or-later](LICENSE)，你可以查看、修改和自行构建，也可以遵循许可证进行商业使用和再分发。自行连接的第三方 AI 服务可能另行收费。

### 与 Raycast、SuperCmd V2 相比

| | Keylane | Raycast 2 | SuperCmd V2 |
| --- | --- | --- | --- |
| 界面与架构 | Swift + SwiftUI / AppKit 原生界面 | Swift / AppKit 宿主 + WKWebView 中的 React / TypeScript 界面，Node.js 后台与 Rust 核心 | Swift 原生界面，使用 AppKit / SwiftUI |
| 费用 | 完全免费，无订阅或付费功能分级 | 基础功能免费，Pro 等高级功能需订阅 | 一次性付费，提供 7 天试用 |
| 开源 | 当前源码以 GPL-3.0-or-later 开源 | 主应用为专有软件；扩展库开源 | V2 源码不公开；免费开源的是 V1 |
| 日常工具 | 应用与文件搜索、剪贴板、计算器、窗口操作等 | 基础版包含常用启动器工具及扩展 | 原生 Swift 启动器，包含常用工具与 AI 集成 |
| Raycast 扩展 | 暂不提供完整兼容 | 官方扩展生态 | 官方称支持多数扩展，部分认证方式不支持 |

**原生界面，专注轻量体验。** Keylane 的启动器使用 SwiftUI 与 AppKit 直接构建，不以 WebView 承载主界面，减少主界面对网页运行环境的依赖。SuperCmd V2 同样采用 Swift 原生路线；Raycast 2 则采用原生宿主与 Web 界面的混合架构，并非 Electron。Raycast 1 的核心界面原本也是 Swift / AppKit，不能与新版混为一谈。参见 [Raycast 官方架构介绍](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)。

技术路线不等于性能排名。实际启动速度、搜索延迟和内存占用取决于版本、数据量与启用功能；这里不宣称未经同条件测试的倍数优势。

Keylane 更适合希望免费使用日常工具，并能查看和修改应用源码的用户；它不是 Raycast 全部功能与扩展的等价替代品。

对比依据：[Raycast 定价](https://www.raycast.com/pricing)、[软件条款](https://www.raycast.com/terms-of-service)、[开源扩展库](https://github.com/raycast/extensions)及 [SuperCmd 官网](https://supercmd.sh/)（2026-11-16）。具体套餐与功能以各产品当前说明为准。

## 从 Raycast 迁移

Keylane 支持读取 Raycast 导出的 **`.rayconfig` 配置文件**和 **Quicklinks JSON**，把支持的数据迁移过来。

1. 在 Raycast 中[导出配置](https://manual.raycast.com/settings)。
2. 打开 Keylane 的 **设置 → 高级 → 从 Raycast 迁移**，选择文件；加密备份按提示输入密码。
3. 查看迁移预览和冲突提示，选择保留现有配置或覆盖冲突项，确认后完全退出并重新打开 Keylane。

| 可以迁移 | 范围 |
| --- | --- |
| 快捷链接 | Quicklinks 的名称和链接；不支持的占位符或目标会跳过 |
| 基本偏好 | 支持的外观、窗口模式、导航、返回延迟等设置，以及启动器快捷键 |
| 命令配置 | 可准确对应的内置命令、已发现应用的别名、启用状态和支持的快捷键 |

## 接下来

Keylane 将继续完善日常体验，并逐步加入 Raycast、SuperCmd 中更多实用功能。扩展兼容、更多 AI 工具及工作流能力属于后续规划，不代表当前已支持，也不承诺与其他产品完全兼容。具体方向见 [开发计划](docs/TODO.md)。

## 安装

要求 **macOS 26 或更新版本**。目前提供 Apple Silicon 安装包，Intel 和通用二进制暂未验证。

1. 前往 [Releases](https://github.com/Acckion/Keylane/releases) 下载 DMG 和 SHA-256 校验文件。
2. 核对校验和，打开 DMG，将 Keylane 拖入“应用程序”。
3. 打开 Keylane，按 **Option + Space** 开始使用。需要时再为相应功能授予权限。

Raycast 配置迁移请从源码构建；当前 Beta 1 安装包尚未包含此功能。

当前公开安装包为 **1.0.2 Beta 1**，采用临时签名，未经 Apple 公证，需要手动安装。

### 首次打开被 macOS 拦截时

若提示“无法验证开发者”或“Apple 无法检查其是否包含恶意软件”，请先确认安装包来自本项目 Releases、校验和一致且未被篡改。未签名或未公证的软件可能危及 Mac 和个人信息；确认信任后，可按 [Apple 官方说明](https://support.apple.com/en-us/102445) 仅为 Keylane 添加例外：

1. 在“应用程序”中尝试打开 Keylane，关闭提示。
2. 打开“系统设置 → 隐私与安全性”，向下滚动，找到 Keylane 对应的“仍要打开”并点击。
3. 在再次出现的提示中点击“打开”，按系统提示完成确认。

无需关闭 Gatekeeper 或使用终端移除安全限制。若提示“将损坏你的电脑”“包含恶意软件”或“已损坏”，请停止打开，不要绕过警告，并向项目反馈。

## 数据与权限

- **本地保存**：设置与历史数据保存在 Mac 上，没有内置遥测或云同步。剪贴板可能包含敏感内容，可按需调整持久化与保留策略。
- **按需授权**：文件搜索使用你选择的目录；自动粘贴、窗口操作等功能可能需要辅助功能权限，部分系统集成需要自动化或对应资料的访问权限。
- **AI 由你决定**：使用文件 AI 时，只有主动提交才会把问题和所选上下文发送至你配置的服务商；上下文可能包含文件名、路径或内容。服务商的数据政策和费用适用，密钥保存在 macOS 钥匙串中。

## 从源码构建

Keylane 使用 **Swift、SwiftUI 和 AppKit** 构建。需要 macOS 26+、Swift 6 工具链和 Python 3；SQLite 使用系统库。

```sh
git clone https://github.com/Acckion/Keylane.git
cd Keylane
git switch dev
swift test
swift build -c release
bash scripts/package.sh
```

开发时可以一键编译并安装当前检出的代码。

```sh
bash scripts/install-local.sh
```

脚本使用本机钥匙串中的 Apple Development 证书，验证后安装并启动 `/Applications/Keylane.app`。上一版保存在 `dist/local-backups/`。多张开发证书时，可通过 `KEYLANE_SIGNING_IDENTITY` 指定证书名称或指纹。

打包默认使用本机配置的签名身份。没有开发证书时，本地试用可使用临时签名：

```sh
KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh
```

临时签名不等于 Apple 公证，升级后可能需要重新授权。详见 [签名与升级授权](docs/SIGNING.md)。

## 参与贡献

欢迎提交问题与改进建议。报告问题时，请附上系统版本、复现步骤和脱敏后的错误信息。

开发前请阅读 [贡献指南](CONTRIBUTING.md)、[协作规范](AGENTS.md)、[行为准则](CODE_OF_CONDUCT.md) 和 [安全政策](SECURITY.md)。功能分支通过 PR 合入 `dev`，稳定快照再同步至 `main`。开发计划见 [TODO](docs/TODO.md)。

## 致谢

Keylane 的功能构想与交互设计受到 [SuperCMD V1](https://supercmd.sh/en/v1) 和 [Raycast](https://www.raycast.com/) 的启发。开发过程中还参考了 SuperCMD V1 的公开源码，以及 Raycast 已分发程序中可观察到的剪贴板数据组织、持久化和处理机制，并据此编写 Keylane 的实现。

## 许可证

当前源码采用 **[GPL-3.0-or-later](LICENSE)**，允许依照许可证条款使用、修改和再分发，包括商业使用。第三方组件及数据适用各自条款，见 [第三方声明](THIRD_PARTY_NOTICES.md)。

历史标签与安装包仍适用随附的许可证，包括 1.0.2 Beta 1 的 PolyForm Noncommercial 许可；当前许可不追溯变更旧版本。
