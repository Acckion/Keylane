# Keylane

面向 macOS 的原生键盘启动器，使用 Swift、SwiftUI 和 AppKit 构建。通过一个搜索窗口打开应用、查找文件、查看剪贴板历史，并调用常用系统工具。

## 功能与进度

| 模块 | 当前能力 | 边界 |
| --- | --- | --- |
| 应用启动 | 应用发现、本地化名称、拼音及模糊搜索、收藏 | 部分多屏和输入法交互仍待验证 |
| 文件搜索 | Spotlight 与本地补充索引、多目录、忽略规则、内容搜索 | 依赖目录授权和索引状态 |
| 文件操作 | 打开、打开方式、Finder 定位、Quick Look、路径复制、系统分享入口 | 完整安装版流程及分享服务结果仍待验收 |
| 剪贴板 | 文字、图片、文件历史，可选持久化、搜索、置顶与清理 | 自动粘贴和真实目标应用仍需实机验证 |
| 文件 AI | 自行配置 OpenAI 兼容接口，选择是否附带路径或内容 | 真实服务商、费用和权限流程尚未完整验收 |
| 系统工具 | 基础四则运算、截图至剪贴板、取色、系统朗读 | 各项系统权限和交互需按场景验证 |
| 设置 | 独立设置窗口、外观、快捷键、搜索范围 | Hyperkey、登录启动等仍有待验收项 |

便笺已有基础实现但暂缓扩展；快捷链接目前只有单个默认链接。文字片段、完整扩展系统、同步、窗口管理及完整 AI 代理尚未完成。详细计划见 [后续待办](docs/TODO.md) 和 [功能清单](docs/FEATURES.csv)。

## 构建与运行

你可以直接从 [Release](https://github.com/Acckion/Keylane/releases) 中下载发布版本，也可以从源码构建。

要求 **macOS 26 或更新版本、Swift 6 工具链、Python 3**。可使用 Xcode 提供的工具链；项目没有第三方 Swift 包依赖，SQLite 使用系统库。

```sh
git clone https://github.com/Acckion/Keylane.git
cd Keylane
swift test
swift build -c release
bash scripts/package.sh
```

解压 `dist/Keylane-<版本号>-macos-<架构>.zip`，将 `Keylane.app` 放入“应用程序”后打开。默认使用 **Option + Space** 唤起，也可从菜单栏打开；按 **Escape** 隐藏。

打包脚本默认使用本机 Apple Development 证书并固定签名身份。无证书时，仅用于本地试用可显式选择临时签名：

```sh
KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh
```

临时签名更新后可能需要重新授权。项目尚未公证；当前主要在 Apple Silicon 上开发，Intel 及通用二进制发行尚未验证。签名配置见 [签名与升级授权](docs/SIGNING.md)。

## 数据与权限

- 数据保存在本机的 Application Support/Keylane 及系统偏好设置中；剪贴板历史可能包含敏感内容，请按需开启持久化和保留策略。
- 文件访问范围由用户选择；自动粘贴等功能可能需要辅助功能权限，读取 Finder 选中项可能需要自动化权限。拒绝权限会影响对应功能。
- 没有内置遥测或云同步。文件 AI 会在用户主动提交时向所配置的服务发送问题及所选上下文，可能包含文件名、路径或内容；服务商可能计费，适用其数据政策。
- AI 密钥通过 macOS 钥匙串保存。不要提交密钥、签名证书、用户数据库或个人文件。

## 项目结构

```text
Sources/Keylane/          应用界面、系统集成及控制器
Sources/KeylaneCore/      检索、数据存储及核心逻辑
Tests/KeylaneCoreTests/   核心自动化测试
Tests/Integration/       隔离集成验证入口
scripts/                 打包、签名及验证脚本
docs/                    设计、开发记录、验证证据及待办
```

`docs/` 中的版本记录描述各轮当时的状态，不代表当前所有功能均已完成验收。自动化或隔离验证不能代替真实账号、真实目标应用及完整安装版交互验收。研究目录、第三方分发产物、构建缓存和本机签名配置不属于本仓库发布内容。

## 设计启发与致谢

Keylane 的功能构想与交互设计受到 [SuperCMD V1](https://supercmd.sh/en/v1) 和 [Raycast](https://www.raycast.com/) 的启发。开发过程中还参考了 SuperCMD V1 的公开源码，以及 Raycast 已分发程序中可观察到的剪贴板数据组织、持久化和处理机制，并据此编写 Keylane 的实现。

## 许可证与商业授权

本项目采用 [PolyForm Noncommercial License 1.0.0](LICENSE)：源码公开，允许许可证规定的非商业使用、修改及再分发；许可证也明确允许某些非商业组织的使用，具体以英文正文为准。

**商业用途不在本许可证的免费授权范围内，需事先取得单独的书面商业授权。** 商业授权及合作请通过 [作者 GitHub 主页](https://github.com/Acckion) 公示的联系方式联系；联系或提交请求不等于已获授权。


## 参与贡献

欢迎提交问题或改进建议。提交问题时请提供系统版本、复现步骤和经脱敏的错误信息。提交代码前运行 `swift test`，涉及系统能力时请区分自动化验证与实际交互结果。

贡献应为你有权提交的内容，不得包含第三方私有代码、品牌素材或个人数据。希望贡献内容同时纳入商业授权的，请先与维护者明确相应授权；仅提交补丁不代表转让版权或授予额外商业权利。

## 开发与自动发布

协作规范见 [AGENTS.md](AGENTS.md)。新任务从 `dev` 创建功能分支，完成检查后通过 PR 合入 `dev`；一批功能完成必要验证后，再通过 `dev → main` 的发布 PR 合入发布分支。

[version.json](version.json) 统一管理版本和构建号。每次合入 `main` 必须同时提升二者，发布 PR 标题为 `release: vX.Y.Z`，并使用 Squash 合并形成一个发布提交。

[GitHub Actions](.github/workflows/ci.yml) 会对 `dev` / `main` 的 PR 和提交执行版本检查、核心测试、Release 构建、包内容与签名校验，并保存构建产物。只有 `main` 检查成功后才自动创建 `vX.Y.Z` 标签及 GitHub Release，附带 Apple Silicon ZIP 和 SHA-256 校验文件。当前自动构建使用临时签名，**未进行 Apple 公证**。
