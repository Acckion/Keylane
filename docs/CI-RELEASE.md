# CI 与正式发布

普通 PR、dev/main push 只运行 `CI / Checks`。该名称继续用于现有分支保护，不修改 required checks。版本格式、脚本与 Swift 编译测试始终执行；main PR 额外限制同仓库 dev 来源，不要求 release 标题、版本提升或发布说明。

DMG 验证覆盖 workflows、scripts、Resources、Package.swift/Package.resolved、.swiftpm、LICENSE、THIRD_PARTY_NOTICES.md、version.json 的变化（含删除和重命名）。push 比较事件 before 到当前提交；PR 比较 base 到合并测试提交。未知基线保守打包。普通源码变更由 Swift 编译测试验证；需要完整安装包时在 CI 手动入口勾选 `validate_installer`。CI 不读取发行 secrets，产物为临时签名、未公证的测试包。

## 正式发布操作

1. 在 dev 准备候选：版本大于已有正式版，构建号大于所有公开版本（包括 Alpha/Beta），填写 `docs/releases/vX.Y.Z.md` 并完成必要实机验收。通过 dev → main PR 同步，确认最终 main SHA 的 `Checks` 成功。
2. 在 Actions 选择 **Release → Run workflow → main**，输入同一 main 提交的完整 40 位 `target_sha`。运行开始后若 main 移动，应核对该运行的固定 SHA；输入与运行 SHA 不同将失败。仅输入 SHA 不会切换到其他提交。
3. 工作流重新校验元数据、公开 tag 版本/构建号、发布说明、脚本、Swift 测试；必须配置 Developer ID 证书与 Apple 公证 secrets。完成签名、公证、staple 及 distribution 验证后上传固定 SHA 的制品。
4. publish job 仅在上述全部成功后获取 `contents: write`，从同一运行下载制品，核对提交标记及 SHA-256，再创建草稿并上传完整资产，最后发布。不同提交已有 tag 将失败；已发布资产不覆盖。同提交的未发布草稿可以重试补全。

没有 push 或 workflow_run 发布入口。普通 main 同步无须先发布或删除 Release。当前 dev 的版本与 Beta 可能共用构建号；这不会阻止普通同步，但必须在下一次公开发布前递增。

## 合入与验收

本次 PR 面向 dev。合入后先确认 dev 的 Checks；再创建同仓库 dev → main 同步 PR，确认 Checks 针对最终 SHA 通过、包含新的两个工作流和策略脚本，并核对公开范围、GPL 与第三方声明。main 当前仍有旧工作流时，必须让该同步提交完整带入拆分；不要手动触发 Release。分支保护保持严格 Checks 要求，不直接推送 main。

正式发布的凭据、公证服务、真实 GitHub Release 写入只能在另一次明确发布操作中验收；本次不运行发布、不创建 tag、不安装应用、不合并 main。
