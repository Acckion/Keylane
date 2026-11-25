# M0 第三批：受限 JS 执行与内核父身份约束

日期：2026-11-21；基线 dev `036cfd72427a14204a7ccd1c5a9e4f67579aded8`，保留新增听写修复。#222 仍为 `c7b4197` 草稿，本批未修改。用户明确保持严格隔离目标、不恢复 VM、不转受信扩展模式。

## 结论与范围

完整 Node 加 App Sandbox 的两轮候选仍是 blocked，没有删除其失败用例。本批新增**第一方对照候选**：独立签名 macOS helper 内使用系统 JavaScriptCore，脚本没有 Node 运行时/原生模块能力。18 项子检查通过，整体标为 **incomplete（退出码3）**，不是 M0 安全批准。

这不是在 Node 内删除 `process`、拦截 require 或修改全局对象后宣称安全；该进程根本不加载 Node，也不向脚本提供文件、网络、进程、通用 ObjC 或 FFI 接口。仅有一次性的测试进入事件回调，无参数、无对象返回、不提供业务能力。不使用私有沙箱接口。

JavaScriptCore 文档中的 `JSVirtualMachine` 指 JS 引擎的执行资源，不是 Linux/操作系统虚拟机：没有来宾内核、虚拟设备、磁盘镜像或 Virtualization.framework。本批不更换产品引擎、启动流程或 API 兼容清单。

## 已实现的原语

1. **内核父身份约束**：helper 签名嵌入 `--launch-constraint-parent`，要求第一方 launcher 的 signing identifier 和 team。允许路径成功执行同一有效脚本；直接启动 helper 被 SIGKILL，使用相同证书但错误 identifier 的父进程无法启动它。不能仅凭同team或知道nonce准入。
2. **无原生能力的 JS 环境**：普通JS数组/函数计算成功；process/require/fetch/Worker/ObjC/dlopen/脚本shell函数不存在，通过Function构造器访问全局也没有process。它们是“接口未提供”的证据，不能改称 Node API 已实现或 OS 拒绝所有原生调用。
3. **每次全新进程与上下文**：前一次写入JS全局的标记在下一次不存在。没有在同一上下文只清理几个字段后复用。
4. **原生父死亡监督**：launcher 独占写端、helper 持有只读FD3；多余FD不继承。原生线程在内核EOF时 `_exit`，不依赖JS任务队列或清理回调。脚本报告已进入后维持死循环，再只杀父进程，helper随之退出。
5. **负对照**：单独编译禁用监督线程的第一方变体，其他启动约束、脚本和签名相同。父退出后它仍运行，由测试器最后清理；证明不是“JS还没启动”或OS偶然终止。
6. **宿主文件控制**：普通宿主能读自建文件；helper的原生open控制返回EPERM。分别测试程序相邻与独立宿主临时目录。该控制不作为JS可调用接口导出。

签名与entitlements执行前后核验；启动器固定相对路径，不接受manifest指定可执行文件；source仅通过有界stdin输入。限制输入64KiB、输出结果32KiB、禁用core dump与JS inspector。测试遥测通过无缓冲管道读取，避免预读两帧后误等下一次fd就绪。

调试中发现Objective-C比较结果被NSNumber编码为数字0，导致驱动将实际EPERM错误标记为失败；已显式编码BOOL，并新增拒绝数字冒充布尔值、拒绝ENOENT作为权限拒绝的测试。没有放宽沙箱或把不可访问文件误当成数据隔离证据。

[去标识报告](evidence/macos-runtime-m0/restricted-js-probe.json)保存实际结果。取消时延是单次第一方微型探针数据，不是p95/SLA，不替换整体资源预算。

## 与原 Node/Raycast 方案的差异

| 能力/条件 | 此候选现状 | 产品决策前必须补齐 |
|---|---|---|
| 普通JavaScript | 首方纯计算通过 | 真实编译产物、错误/取消、资源预算 |
| CommonJS/ESM、Buffer、Node内置模块 | 未提供 | 明确可适配子集、依赖与模块加载策略，不能动态回退到Node |
| React/reconciler、List/Grid/Form/Detail | 未接入 | 公共页面协议和事件、调度/定时器验证；不重写产品UI样式 |
| LocalStorage/Cache/偏好 | 未提供 | 宿主代理按安装命名空间隔离、版本迁移、撤权与重启恢复 |
| 文件与网络 | 无脚本原生入口 | 显式、有界代理及授权校验，不转发任意路径、fd或原生命令 |
| child_process/native addon/ObjC | 无脚本入口 | 不因兼容自动放开；依赖者明确不兼容或重新设计固定宿主能力 |
| 启动身份 | 固定签名parent正/负对照通过 | 制品收据、当前安装/模块代次、协议握手、复制真parent再注入伪造安装等仍需验证 |
| 父死亡/死循环 | 有原生EOF监督和禁用监督器对照 | 权限撤销、宿主重启、资源超限、协议取消及更广工作负载 |
| 槽位/数据残留 | 仅验证新进程没有旧JS全局 | 未证明整个helper容器净化；未来代理不得把明文用户内容写进共用容器 |

禁止把“新的纯JS候选没有Node接口”计入已有兼容CSV的implemented计数。未启动公开扩展，不把第一方计算当作真实Raycast验收。选择产品执行核心前必须拿固定版本最小no-view/view/storage样例比较兼容差异；替换引擎或改变对用户的兼容范围须明确决定。

## 尚未解决的 M0 条件

- 本批没有业务 broker；内核父约束不是完整的“当前安装有权执行”证明，持有真实签名parent的进程仍需会话/制品/代次准入。
- 原 Node 的任意子进程和detached逃离仍存在；没有声称这批修复了Node路径。
- Keychain、native addon、直接宿主服务、全容器无残留证明、引擎漏洞逃逸、内存耗尽等未覆盖。不存在“18项全过所以全部安全”的结论。
- 生命周期负对照只证明当前纯JS、无原生创建后代接口的工作负载；不是通过PID扫描证明任意不可信进程树已退出。
- 下一项仍为M0：最小有界broker的身份/代次/存储命名空间验证，以及Node依赖与React执行的兼容差异实验。M1保持未开始。

## 复验

```sh
python3 scripts/verify-macos-restricted-js-m0.py --report /private/tmp/keylane-restricted-js-report.json
```

需要本机有效Apple Development身份，绝无ad-hoc回退。脚本仅在临时目录构建第一方launcher/helper，不安装，不导出证书，不读真实用户内容。负对照helper只在Tests中由宏编译，不能由JS/manifest/运行参数选择；不进入产品包。退出2表示观测失败，3表示子集通过但M0缺项；代码没有生产通过出口。

参考：[Apple启动约束](https://developer.apple.com/documentation/security/constraining-a-tool%27s-launch-environment)、[JSContext](https://developer.apple.com/documentation/javascriptcore/jscontext)。新探针源码见 [RestrictedJS](../Tests/ExtensionPrototype/MacOSRuntimeM0/RestrictedJS/Helper.m)。

## 本批交付检查

404项Swift、45项Python检查通过，版本/源码差异/本地文档链接检查通过。当前dev基线的ARM64 Debug 1.0.2/build27测试包用本机Apple Development签名，布局、元数据、许可证、文件清单、架构及签名校验通过；探针未进入该包，未安装或发布。native helper/launcher正负对照结束后确认无自建进程遗留。

本批以`036cfd7`固定源码验证；交付复核时远端dev已前进到`01cee5a`，未把验证期间的其他任务改动混入当前探针，也未将此次包称为该新dev头的验证。后续批次开工重新核对基线。未修改#222、未推送或合并。
