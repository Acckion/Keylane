# 本机开发签名与升级授权

旧打包脚本使用 codesign --sign -。实际安装版的 designated requirement（DR）只有当前二进制 cdhash，因此每次代码改变后，旧授权中的身份约束可能无法继续匹配。

新打包流程使用固定的真实签名身份：

- 首次优先选择本机唯一有效的 Apple Development 证书，将证书指纹固定到本地 `.signing-identity`。
- 该选择文件已加入.gitignore，只保存证书指纹；私钥仍在钥匙串，不复制到项目或发行包。
- 可用 `KEYLANE_SIGNING_IDENTITY` 指定另一张有效证书的完整名称或指纹。身份不唯一、证书失效或不可用时，构建明确失败，不悄悄退回临时签名。
- 无证书的临时测试需显式 `KEYLANE_ALLOW_ADHOC=1`，并接受升级后可能重复授权。
- Bundle ID保持org.keylane.launcher，安装位置保持/Applications/Keylane.app。安装保留原资料库、偏好和文件夹书签。
- 本机开发使用Apple Development；公开发行仍需项目所有者的Developer ID、公证与对应发行配置。

从旧临时签名首次切换到新证书时，旧DR不兼容，文件访问/辅助功能/自动化等可能需要最后重新授权一次。以后应持续使用兼容的签名身份；更换Team、Bundle ID、撤销权限或系统策略变化仍可能触发授权，不承诺任何情况下永不弹窗。

## 本轮验证

当前0.9.1运行文件重新打包为固定证书签名版本，不混入其他尚在开发的代码。对临时副本修改构建号后重新签名，两版均通过严格签名检查：

- REAL_CERTIFICATE=true
- HASH_PIN_REMOVED=true
- DESIGNATED_REQUIREMENT_STABLE_ACROSS_CHANGED_BUILD=true

验证的是身份要求稳定；尚未完成“用户授权第一版→安装下一版→系统沿用授权”的完整TCC实机闭环。没有编辑、清空或重置系统授权数据库，没有扩大应用权限。

Apple文档：
https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
https://developer.apple.com/library/archive/technotes/tn2206/

## GitHub Actions 发行签名

在仓库的 **Settings → Secrets and variables → Actions** 添加以下 Secrets：

| Secret | 内容 |
| --- | --- |
| `KEYLANE_DEVELOPER_ID_P12` | Developer ID Application 证书和对应私钥导出的密码保护 `.p12`，以 Base64 编码 |
| `KEYLANE_DEVELOPER_ID_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `KEYLANE_NOTARY_APPLE_ID` | 用于 Apple 公证的 Apple Account 邮箱 |
| `KEYLANE_NOTARY_TEAM_ID` | Apple Developer Team ID |
| `KEYLANE_NOTARY_APP_PASSWORD` | 上述 Apple Account 生成的 App 专用密码 |

CI 只在 `dev` 和 `main` 的分支构建中使用这些凭据。它对应用启用 Hardened Runtime 和安全时间戳，签名 DMG，然后提交 Apple 公证并附上票据。验证通过后才生成 SHA-256 校验文件。配置后可在 Actions 手动运行 `dev` 验证签名和公证，再从 GitHub 下载 DMG 试装。

缺少全部凭据时，`dev` 仍生成临时签名的测试 DMG，`main` 会停止发布。仅设置部分凭据也会使发行构建失败。

参阅 [Apple Developer ID 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) 和 [Apple 公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
