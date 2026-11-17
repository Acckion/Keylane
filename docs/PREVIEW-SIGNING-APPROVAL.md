# 测试包签名审批准备（尚未启用）

本设计保留 #152 的 Apple Development 测试包签名和原正式版 Developer ID/公证流程；只准备代码及无密钥测试，不修改 GitHub 设置，不导出或上传证书，不发布软件。

## 已核查的现状（2026-11-17）

公开仓库支持环境审核者。现有 `preview-signing` 允许 `dev`、`main`、`refs/pull/*/merge`，没有 required reviewers，管理员可绕过。只读列出的仓库级与该环境 Secrets 名称列表为空。**不能向当前配置直接加入证书后就宣称同仓 PR 已有人工审批。** 未读取任何密钥值。

## 准备的代码

Checks 不接触签名凭据。范围检查要求生成 DMG 时，dev/main 的 push 或手动运行进入 `preview-signing-auto`；同仓非 Dependabot PR 进入 `preview-signing-pr`。fork 和 Dependabot 仅无密钥检查，合入后在集成分支签名。所有构建 checkout 固定为事件完整 SHA，不使用可移动分支或下载 PR 可写制品/缓存。

PR job 名称显示 head 和 merge SHA，审批前检查这份完整代码。审批后、导入凭据前重新读取 PR，核对仍开放及相同仓库、目标分支、head、base、merge SHA。新提交或基线变化须新运行重新审核；旧 PR run 的 `run_attempt > 1` 拒绝签名，不假定重跑会再次要求平台批准。失败后应产生新的 PR 事件运行并审核，不能直接绕过此限制。

检查后若 PR 又更新，已固定的 checkout 仍只构建原来审核的快照；并发取消是辅助措施，不是瞬时撤销保证。GitHub-hosted 临时 runner、不保留 Git 凭据、固定 action SHA，签名结束或失败都会尝试清理临时 keychain。安装包仍未公证，不变成正式发布。

## 必须由用户另行确认并配置的安全边界

1. `preview-signing-auto`：使用 Selected branches and tags，只建 **Branch** 类型的精确 `dev`、`main` 两条；不允许 tag、PR refs 或通配分支。此环境不设人工审批，以满足已集成分支自动签名。
2. `preview-signing-pr`：仅允许 **Branch** 规则 `refs/pull/*/merge`；Required reviewers 需要用户指定实际维护者；禁用管理员绕过。建议开启 Prevent self-review，但若唯一审核者也是运行触发者将无法批准，须用户确定另一个真实审核者或明确选择允许自审批，不能由助手默默代选。
3. 旧 `preview-signing` 不再被代码引用；先保持无秘密。若以后保留或加秘密，也必须移除不受审核保护的 PR 访问，不能让其成为旁路。
4. 用户自己将 `KEYLANE_PREVIEW_P12` 和 `KEYLANE_PREVIEW_P12_PASSWORD` 配置在上述受限环境内。不得放进 Repository/Organization Secrets，也不能在其他无等效保护环境重复配置。助手不读取、导出或传输其值。
5. 保留 dev/main 严格 Checks、禁止强推与既有保护；不得以放松保护来解决签名失败。实际环境设置配置完成后，还要用**无真实凭据的隔离验证**确认 PR 引用 auto 环境会被平台拒绝、PR 环境会等待维护者、新提交会产生新审批。

以上每项设置均尚未实施，审核者/自审批选择尚待用户确认。环境不存在、缺少秘密或目标核对失败时，不应宣称可交付真实签名包。

## 防绕过与剩余风险

同仓 PR 可以改 YAML、删 if、改检查脚本、替换构建步骤，所以 Python/YAML 测试仅证明准备代码行为，**不能代替 GitHub 服务器的环境保护**。PR 改名引用 auto 环境应被其 ref policy 拒绝；引用 PR 环境仍需维护者批准；创建新环境无证书可用。不能把仓库级秘密留作 fallback。

批准签名意味着信任该次运行的全部 action、构建脚本和代码，不只是信任 Checks 绿灯。已批准的恶意代码仍可能访问本次 runner 的签名身份或秘密；这不是 if 条件能消除的风险。工作流不使用 `pull_request_target` 或 `workflow_run` 的高权限链，不下载未信任制品到密钥 runner 执行。若将来要自动处理未审核代码，必须重新设计独立签名服务，而非扩大本次权限。

## 官方依据

- [部署环境规则及 Secrets](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)：分支/ref 限制、审核者与 Secrets 的服务器边界。
- [审核部署](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments)：批准、自审批和管理员绕过行为。
- [安全使用 pull_request_target](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target)：避免在有凭据的上下文运行未审核代码。
