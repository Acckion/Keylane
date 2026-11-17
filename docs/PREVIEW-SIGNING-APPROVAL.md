# 合入后测试包签名（尚待环境验证）

## 最新决定

用户决定不为未合并 PR 生成测试包，以缩短审查时间。同仓库及 fork PR 仅运行无密钥 Checks；只有 dev/main push 在 Checks 成功且安装包范围检查需要时构建签名 DMG。手动 CI 仅检查，不签名。PR 签名环境与人工签名审批流程已移除。保留原 Apple Development 签名，正式 Developer ID/公证发布流程不变，不创建 Release/tag。

## 实现与验证边界

唯一签名 job 为 `sign-preview-auto`，仅接受 push + 精确 refs/heads/dev/main，checkout 固定事件 SHA，导入凭据前再次验证事件、ref 与 checkout。Checks 不引用任何 secrets/environment，不打包、不上传安装包；所有 PR 均无例外。目标检查脚本及测试无需 GitHub API token。临时 keychain 始终尝试清理。测试包仍未公证。

## 必须单独确认的服务器设置

- `preview-signing-auto` 使用 Selected branches and tags，仅 **Branch** 类型 `dev`、`main`；不允许 PR refs、tag 或通配分支。无需 Required reviewers。
- 禁止管理员绕过环境保护；保持 dev/main 现有保护。
- 旧 `preview-signing` 和任何 `preview-signing-pr` 保持无签名秘密；不要未经确认删除或修改环境。若已有秘密，需另行安排移除不受保护的入口。
- 用户自己将 `KEYLANE_PREVIEW_P12` / `KEYLANE_PREVIEW_P12_PASSWORD` 配置到受限 auto 环境，不得配置在仓库/组织级或无等效保护环境。
- 配置后用无真实凭据的隔离测试验证普通 PR 即使改 YAML 引用 auto 环境也会被服务端拒绝。未做此验证或未配置凭据前不能宣称签名链可用。

普通 PR 可以改 YAML 和脚本，因此 job if 与本地单元测试仅为纵深防御；真正保密边界是服务端 ref 限制与秘密只存于受限环境。禁止引入执行未审核 PR 代码的 pull_request_target/workflow_run 链。已合入代码受 dev/main 分支保护；管理员本身修改环境策略的权限不由此代码消除。

本次仅代码和测试，不修改 GitHub 安全设置，不读取或传输凭据，不合并、不发布。

[GitHub 环境保护规则](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
