# Contributing to Keylane / 参与贡献

Thank you for helping improve Keylane. Bug reports, documentation, translations, accessibility feedback, and focused code contributions are welcome. Chinese and English reports are both welcome.

## Before starting

- Search existing issues and pull requests to avoid duplicate work.
- Discuss substantial changes before implementation, especially architecture, permissions, data migration, and user-visible behavior.
- Read [AGENTS.md](AGENTS.md), [README.md](README.md), and the relevant module notes in [docs](docs/).
- Report security vulnerabilities according to [SECURITY.md](SECURITY.md), not in a public issue. Follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Development and branches

Keylane requires macOS 26+ and Swift 6. Apple system integrations and UI validation require a Mac; Linux checks are not a substitute for macOS acceptance.

1. Fork or clone the repository and branch from the latest `dev`.
2. Use a focused `feat/`, `fix/`, `docs/`, or `chore/` branch.
3. Keep changes limited to one purpose and preserve unrelated work.
4. Open a **draft pull request targeting `dev`**, not `main`.
5. Use a clear conventional title, for example `fix: preserve clipboard selection` or `docs: improve setup instructions`.

The normal flow is `feature branch → dev → main`. Release/version procedures are defined in AGENTS.md and the repository workflows. Contributors should not create release tags or change version/build numbers for ordinary development work unless the task requires it.

## Checks and evidence

Run applicable checks and state exactly what passed, failed, or was not run:

```sh
python3 scripts/check-version.py
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
swift test --scratch-path .build-current --disable-sandbox
```

For packaging changes on macOS:

```sh
KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh
python3 scripts/verify-package.py
```

The explicit ad hoc option is for test builds only; it is not Developer ID signing or Apple notarization. Read [docs/SIGNING.md](docs/SIGNING.md) before changing distribution behavior.

For UI or system integrations, include actual macOS interaction results and relevant screenshots with personal data removed. Check keyboard navigation, focus, repeated/cancelled flows, and light/dark appearance as applicable. See [ACCESSIBILITY.md](ACCESSIBILITY.md). Do not describe simulated tests or CI success as full real-device acceptance.

## Reports and pull requests

Use the issue forms and PR template. Include the affected version/build, macOS version, reproducible steps, expected/actual results, scope, and known limitations. Link related issues; use closing keywords only when the work actually resolves the issue.

Never upload passwords, tokens, clipboard history, private documents, raw settings exports, signing certificates, or unsanitized logs. Trim screenshots and redact names, paths, accounts, and other private content.

## Licensing

Submit only work you have the right to contribute. Original contributions to this licensed version must be distributable under **GPL-3.0-or-later**, without transferring your copyright. Preserve third-party licenses and attribution; consult [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Do not copy Raycast/SuperCMD proprietary code, brand assets, or distribution artifacts.

## 中文快速说明

从最新 `dev` 创建独立分支，提交聚焦的改动并开草稿 PR 到 `dev`。遵守 AGENTS.md，明确自动化检查、真实 Mac 验收和未验证项目；文档修改不必假装完成应用实机测试。请先讨论重大行为或架构变化。问题反馈及代码贡献不得包含个人数据、密钥或无权提交的第三方内容。
