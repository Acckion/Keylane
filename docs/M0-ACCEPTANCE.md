# M0 终审：受限 JavaScriptCore 可行性

结论日期：2026-11-23。集成基线 `origin/dev d6a3074c698ff07f562ed036abc0ba07cf4da7eb`，保留#226/#236新合入能力；本分支待合并。#222仍为草稿 `c7b4197`，没有修改其内容或启用商店第三方执行。

## 结论

**M0首方可行性验收通过，可以按受限JavaScriptCore路线进入M1。M1尚未开始，产品运行器仍未交付。**

2026-11-22用户明确批准“允许受限 JavaScriptCore，明确兼容子集并逐步适配”。[决定记录](evidence/macos-runtime-m0/engine-decision.json)保持严格隔离、不恢复VM。原完整Node候选在本批再次验证仍不通过，没有把旧失败改名、删除或当作新引擎的成功。

[统一机器报告](evidence/macos-runtime-m0/final/acceptance.json)检查8组首方证据、125个有重叠的观察断言及其签名／清理状态。每组探针仍返回3/incomplete，表示单独不足以批准整个方案；统一检查只输出 `feasibility-passed`，固定 `productionRuntimeReady=false`、`publicExtensionsVerified=false`、`M1Started=false`，没有更改产品开关。

这不是安全认证或“全部未知攻击已排除”。可信计算基包括系统JSC、固定编译器和应用自己签名的原生代理；脚本没有通用ObjC/FFI/进程/文件/网络入口。OS Sandbox、Hardened Runtime与受控代理共同限制能力。**不宣称App Sandbox禁止任意原生spawn，不证明引擎内存漏洞或任意本机RCE的完整遏制，也不承诺VM等强隔离。**

## 验收矩阵

| M0边界 | 观察与对照 | 证据 |
|---|---|---|
| 签名／父身份／基本执行 | 固定可信父可启动；直接启动、同证书错误父ID被拒绝；普通JS可执行，raw process/require/ObjC/FFI等没有入口 | [18项受限执行](evidence/macos-runtime-m0/final/restricted-final.json) |
| OS文件／链接／网络 | 同一自建目标在普通宿主可访问；受限进程原生open与connect返回真实EPERM/EACCES，不把ENOENT当权限拒绝 | [12项原生边界及编译](evidence/macos-runtime-m0/final/boundary-final.json) |
| 原生动态库 | 普通对照可加载自编库；候选可加载同团队可信库，但拒绝同样可读的无可信发布者库；JS没有动态加载接口 | 同上 |
| 编译器分离 | 固定官方esbuild 0.25.5、摘要校验、Apple Development签名、App Sandbox继承、固定stdin/stdout CLI和无配置／插件参数；第一方副作用源码仅产出文本、未产生目标文件 | 同上；不等同M1完整依赖构建器 |
| 身份、分区和三阶段撤权 | 原生绑定安装命名空间，拒绝自报owner、重放、越界；准备／执行／披露均复核；关再开不能恢复旧绑定 | [17项broker](evidence/macos-runtime-m0/final/broker-final.json) |
| 原始收据和实际注册表算法 | 原样编译#222固定源码，P256签名／内层摘要／recipe／安装／命令／grant／回滚校验；旧lease失效并确认helper退出后才重新启用 | [20项收据桥接](evidence/macos-runtime-m0/final/receipt-final.json) |
| 持久受保护存储原语 | 当前Mac默认Keychain owner ACL；独立签名XPC角色；跨两个服务进程CAS只成功一次；重启仍保留状态；缺失不重建；复制程序、替换锁、错误角色拒绝；禁用对端签名校验的反对照能收到假服务回复 | [20项持久信任原语](evidence/macos-runtime-m0/final/trust-final.json) |
| 协议、退出与压力 | 截断和畸形请求／回复明确失败；原生RPC阻塞时父死亡／期限均结束helper；长度和帧额度检查；内存监督与仅观察对照；无遗留进程 | [19项传输／压力](evidence/macos-runtime-m0/final/transport-final.json) |
| 数据布局与错误 | 不向脚本提供共享容器文件入口；全新进程无旧JS全局；有界扫描本测试容器Library/tmp及系统选定的本应用缓存根，不跟随普通链接；正对照可找到标记，正常执行／错误后未观察到标记落盘；原生SIGSEGV状态正确回传 | [9项观察与崩溃](evidence/macos-runtime-m0/final/privacy-final.json) |
| 编译样例与差异 | 固定esbuild/React19.0.0编译的无界面计算、React元素数据、私有存储桥接可运行；相同程序的Node fs、Buffer、timer对照成功，JSC明确不支持 | [10项编译对照](evidence/macos-runtime-m0/final/compatibility-final.json) |

动态库负样本保留链接器生成的页签名：arm64不能映射真正缺少页签名的Mach-O，因此直接去掉签名会产生无效正对照。该**首方小型库**没有可信开发者身份，只用于库校验反向实验；所有候选／控制执行程序、编译器和测试包仍用本机Apple Development签名，没有ad-hoc应用安装或运行fallback。

持久信任探针使用的是**专属合成槽位与当前Mac的默认owner ACL**，数据是有界opaque测试头，不是用户凭据。它证明持久CAS、独立角色和失效行为可实现；没有把该测试服务当作产品enrollment，也没有替用户配置开发者账户或正式Keychain access group。原始收据算法和持久原语在M0分别验证，M1/M2仍须完成实际产品组合和事务验收。

## 明确兼容子集

| 能力 | 当前M0结论 | 后续归属 |
|---|---|---|
| 普通JS／编译TS | 首方样例可执行 | M1固定工具链和制品，M2接普通命令 |
| JSX／React | 编译和元素数据构造成功 | **不是已挂载reconciler或Raycast List**；原生页面与事件在M2/M3 |
| 存储 | 私有测试桥接与安装分区验证 | 不是公开异步LocalStorage已兼容；M2/M3接真实持久内容 |
| Node builtins／Buffer／定时器 | 当前没有接口，样例明确失败 | 按能力逐项适配；不得动态加载Node来补缺口 |
| 网络／文件 | raw入口不存在；原生控制受OS拒绝 | 后续仅受控代理和显式权限 |
| child_process／native addon／ObjC/FFI | 默认不支持 | 不为兼容开放通用本机执行 |

没有更新API覆盖CSV的implemented数量，没有执行公开扩展，没有承诺全部npm依赖可运行。相同helper身份仍可能共享OS容器；本方案依赖**私有内容留在宿主、JS无文件入口和每次新上下文**，而非声称容器本身变成多租户隔离域。有界扫描不是全容器净化证明。64MiB RSS采样阈值不是硬内存上限，125个观察断言也不是125类独立攻击的穷尽证明。

## 已拒绝的替代方案

- [完整Node复验](evidence/macos-runtime-m0/final/node-rejected.json)：任意系统／Node子进程和共享容器仍允许，终止helper组不能停止全部后代。
- [固定槽位复验](evidence/macos-runtime-m0/final/slots-rejected.json)：普通组和FD问题有改善，但复用残留、任意spawn和detached后代仍使它blocked。

用户已据此选择新的执行核心；不是用Node权限标志、删除require或JS shim伪装隔离。旧测试和报告完整保留。

## 交付检查与清理

本批同步dev的AI模块能力选择及文件操作增量，冲突只在功能记录，双方内容均保留。8组签名首方证据通过统一门槛；447项产品Swift测试、65项Python／脚本检查通过，版本和脚本检查通过。ARM64 Debug 1.0.2/build27 DMG以本机Apple Development签名，包布局、元数据、许可证、资源清单、架构与签名校验通过；M0夹具／编译器／React均未进入产品包。未安装Keylane、未推送或发布，未运行远端CI；包通过不代表扩展产品运行器就绪。

首轮Keychain自定义ACL实验发生布尔编码清理误判，已停止使用该配置。为定位本轮唯一合成项只请求过名称元数据，没有请求密码数据或输出其他项；最终按已记录的精确项目引用完成无交互删除，没有弹窗或更改钥匙串配置。正式探针改为默认owner ACL，先保存精确清理意图；异常时保留原始恢复身份。所有最终探针的合成项及临时用户XPC服务均已删除／卸载。该问题不隐瞒，也不计作隔离通过证据。

## 进入M1时仍必须做的工作

1. 将原语接到实际、不可由请求自登记的profile、公钥、受保护存储、锁inode和安装事务；正式签名／Keychain权限配置独立核对。没有配置时维持仅浏览。
2. 固定darwin构建工具链、完整依赖和资源表、收据策略版本及不可变制品部署；确认源码／依赖／安装钩子不会执行，失败不覆盖有效安装。
3. 后续M2统一命令／运行／能力代次；M3公共页面和持久内容；M4同样本性能与后台；M5准确头集成、实机验收后才移除旧VM代码并切换唯一生产入口。

这些是原有M1–M5交付条件，未从清单删除，也不作为M0已经完成的产品功能。

## 复验

```sh
python3 scripts/check-macos-runtime-m0.py --report /private/tmp/keylane-m0-acceptance.json
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
```

各首方探针命令见同目录前六批文档及新增 `verify-macos-{compatibility,trust,boundary,privacy}-m0.py`。报告输入与SHA-256绑定，缺失、数字冒充布尔、未验证签名、清理失败或任一观察失败均拒绝通过。统一检查不被产品启动器使用，不更改任何运行开关。

机制参考：[Apple App Sandbox子进程与独立服务](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations)、[NSXPC对端签名要求](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))、[macOS Keychain访问控制](https://developer.apple.com/documentation/security/access-control-lists)。这些参考说明机制，实际结果以本次签名探针为准。
