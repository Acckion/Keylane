# Keylane 项目协作规范

本文件适用于本 Git 仓库内的所有文件。修改项目的 agent 必须遵守以下规则。

## 范围与来源

- Git 根目录为 `Keylane/`。上级目录的 `research/`、`work/` 等资料不属于本仓库，不得提交或打包。
- 保留用户未提交的改动，不得自行覆盖、清理、暂存或混入当前任务的提交。存在并行修改时，从已提交基线创建独立 worktree。
- 不得复制 SuperCMD、Raycast 的私有代码、图标、品牌素材或分发产物。参考公开源码时先核对许可，实际复用须保留所需声明；不得把第三方内容全部改标为本项目许可证。
- 不得提交密钥、用户数据、签名证书、本机签名身份、缓存或构建产物。构建产物仅通过 Actions artifacts 和 Releases 分发。

## 分支与提交

固定流程：`功能分支 → dev → main`。

- `main` 是发布分支，只容纳经过验证的最终发布快照；禁止直接提交或直接推送到 `main`。
- `dev` 是开发集成分支。新任务从最新 `origin/dev` 创建 `feat/<主题>`、`fix/<主题>`、`docs/<主题>` 或 `chore/<主题>` 分支；不得在 `dev` 上直接开发。
- 功能分支完成后先运行相关检查，再通过 PR 合入 `dev`。PR 应说明功能变化、验证方式、未完成项及影响。CI 通过不代表已完成实机验收。
- 一批功能开发完成且必要的实际交互验证通过后，才能创建 **dev → main** 发布 PR。不得从其他功能分支直接合入 `main`。
- 发布 PR 使用 **Squash and merge**，令每次 `main` 更新只有一个发布提交；提交标题为 `release: vX.Y.Z`。不得使用普通 merge 或 rebase 向 `main` 一次引入多个开发提交。
- 普通提交采用 `feat:`、`fix:`、`docs:`、`chore:`、`test:` 等清楚的前缀，保持单一目的，避免混入无关修改。
- 禁止强推 `main` / `dev`、改写公开标签或删除已发布版本。修复已发布问题也应走功能分支 → dev → main，并发布新版本。
- 发布后将 `main` 合回 `dev`（通过同步 PR），再继续从更新后的 `dev` 开发，避免 squash 导致版本基线漂移。

## 版本规范

- `version.json` 是版本和构建号的唯一来源；不得在打包脚本中另写固定版本。
- `version` 使用 `MAJOR.MINOR.PATCH`，不带 `v`，不带前导零；`build` 为正整数。
- 每次合入 `main` 必须同时提升版本号和构建号，包含仅修改文档或 CI 的发布。不得复用已发布版本号。
- 修复用 PATCH，向后兼容功能用 MINOR，不兼容变化用 MAJOR。开发分支可沿用当前开发版本；发布 PR 前统一更新。
- 发布 PR 标题须为 `release: vX.Y.Z`，并与 `version.json` 一致。说明已验证的功能、已知限制、兼容性和是否已签名/公证。
- `main` 的自动流程在检查和构建成功后，创建对应 `vX.Y.Z` 标签及 GitHub Release；版本、应用 Info.plist、ZIP 文件名和标签必须一致。
- 当前已有历史提交早于此规范；本规范约束启用后的发布，不要求重写旧历史。

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
- 当前 CI 仅提供 Apple Silicon 临时签名、未公证构建。未完成发行验证前，不得宣称支持 Intel、通用二进制或正式可信分发。
