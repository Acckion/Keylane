# M1：签名构建、收据与安装事务

2026-11-23；EXT-01-a / BASE-11。前序 [M0验收](M0-ACCEPTANCE.md)，本地提交 `4fd73ff1`；本批在独立分支 `feat/macos-extension-build-m1` 继续，并整合当前远端dev `b09c5dd98144853457b66c23545c73dfc13bdbea`（#231）。#222仍为原草稿 `c7b4197`，没有修改其内容。

**M1已完整实现并通过首方签名组合验收，待合并。运行能力仍关闭；M2–M5未开始。**

下方第一批记录保留为阶段历史；本批终审、实际产品边界与复验见文末。 不恢复VM、不改为受信扩展模式、不以Node补齐兼容缺口。

## 已实现

`MacOSExtensionBuild` 位于Core，只有数据契约、结果校验和构建协调，没有默认目录、下载、进程启动、签名密钥或执行器。

- `Plan` 接收已验证来源和依赖展开后的有界文件快照，统一排序并绑定全部文件字节。拒绝路径逃逸、大小写别名、父文件冲突、缺失／重复入口、安装钩子和已识别的原生内容；反序列化重走验证。保留发布包中的惰性prepare元数据，永不执行。
- `Recipe` 固定schema、策略、darwin-arm64目标和esbuild 0.25.5，绑定辅助程序及签名后编译器字节摘要。请求不含编译器路径、可选参数、输出路径或环境变量。实际产品必须从应用自己的签名profile取得它，不能信任调用者自报摘要。
- `Coordinator` 一次只处理一个构建；提交前后复核来源与工具链，取消仅指向当前请求。`Service` 必须在返回前确认其编译进程退出；取消后即使收到结果，协调器也不发布。
- `Artifact` 复核请求ID、配方、项目和完整命令集合，限制输出大小／编码。资源与许可证从原输入复制，不接受helper另报的资源。版本化资源清单绑定路径、长度和SHA-256。

这些摘要证明内容一致性，**不是安装收据、签名或运行授权**。来源提交、registry tarball SRI、锁文件与manifest关系继续由#222来源／依赖验证器负责；本类型不会自行把未验证字节升级为可信来源。没有另建目录注册、偏好存储或授权来源。

## 实际隔离编译

`Tests/ExtensionPrototype/MacOSRuntimeM1/Build.swift` 是未打包的首方原生夹具，与真实Core契约共同编译。测试程序和固定官方编译器均由本机Apple Development签署，执行前后检查Hardened Runtime、证书要求与准确entitlements。编译器archive沿用M0的固定SHA-512校验，签名后摘要单独绑定。

辅助程序使用App Sandbox，编译器继承其限制；经stdin接收数据，在新建私有staging目录处理快照。固定CLI关闭tsconfig发现，不调用npm、shell、JS配置或插件。未支持的Node导入明确失败。metafile引用必须属于输入清单，否则拒绝披露产物；这项检查不声称OS只允许读取staging，也不替代M0的OS边界验证。

父进程存活通道独立于编译I/O。父失联／20秒期限触发取消，原生监督器终止仍未回收的自有编译器；先确认退出，再清理本次scratch。进程号在回收前受锁保护，避免取消信号命中复用PID。源码、编译诊断和机器签名身份不写入报告。

夹具为越界导入对照临时创建一个已知、无害的邻接JS文件，验证“编译器确实读取了非输入文件，但结果没有返回”；精确删除该文件和本次目录。它不是产品的数据布局或向扩展开放的接口。共享helper容器不是租户隔离边界，产品阶段仍须使用应用控制的数据布局和来源验证。

## 验证与边界

[17项真实签名检查报告](evidence/macos-runtime-m1/build-first-batch.json)：多文件及合成依赖打包后在M0受限JSC执行并得到42；相同快照重复打包一致；无效tsconfig被忽略；无限循环源码只编译、不执行；路径／别名／安装钩子／原生内容／错误profile／Node导入拒绝；已存在的邻接输入产生拒绝；观察到真实编译器启动后关闭父存活通道，退出75且scratch清理完成；无遗留自建进程。

报告保持 `gate=incomplete`、退出3，表示**这一批通过，M1仍未完成**。合成依赖只是固定输入快照，不是公开npm包SRI或真实第三方扩展验收。首次夹具因FD3等于原描述符时未清除CLOEXEC而提前拒绝，已修正并完整复验；未把该启动失败计作隔离拒绝。

Core回归覆盖输入／资源摘要、解码绕过、配方替换、旧请求／命令集合、取消、并发和来源中途失效。完整457项Swift、68项Python检查、版本检查和本机Apple Development签名ARM64 1.0.2/build27 DMG校验通过。首轮受执行环境的命名剪贴板／书签服务访问限制而失败，保持原断言在本机服务可访问环境中重跑后通过。未推送或运行远端Checks。没有安装Keylane、访问真实剪贴板历史、修改钥匙串或发布第三方执行能力。

## 第一批结束时的后续清单（历史，现已完成）

1. **产品profile及签名构建服务**：把本机首方验证转为正式签名、对端校验、工具链和受保护根的组合；缺少材料时继续仅浏览。当前`Service`接口没有默认产品实现，测试helper不能作为fallback。
2. **接入#222验证器和版本化收据**：明确darwin平台选择；继续检查固定来源、锁关系、依赖archive和许可证。签名覆盖完整命令、资源、配方和策略；现有只封装命令字节的收据不能直接代表新资源表已受保护。
3. **安装事务**：接入原有受保护注册表和安装代次；验证准备／取消／签名失败不覆盖旧版本、崩溃恢复、原子切换及旧实例撤销。不得另建可绕过原注册表的安装目录或启动入口。

本节记录第一批结束时的状态；上述组合与事务已在下方终审完成，未以17项子集代替整体验收。M2命令运行、M3页面／持久内容、M4性能、M5生产切换与VM代码移除均未开始。

## 复验

```sh
python3 scripts/verify-macos-build-m1.py \
  --compiler-archive /private/tmp/keylane-m1-esbuild-0.25.5.tgz \
  --report /private/tmp/keylane-m1-build.json
swift test --scratch-path /private/tmp/keylane-m1-tests --disable-sandbox
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
```

archive只允许M0固定官方包，不能指向任意编译器或忽略摘要。探针退出3属于预期的阶段未完成状态，缺项、非布尔观察或任一失败均拒绝。


## M1终审（2026-11-23）

前序 `00a23eba`。本批复用#222 `c7b4197` 的来源、依赖、受保护收据、注册表、安装器及对应回归，加入macOS实现；没有修改#222分支或导入其VM驱动。保留当前dev所有变更、旧设置键及数据库。`StoreRuntimeBridge`/ticket历史名称只作为共享数据与协议；新的构建服务不调用旧engine、VM或Node。

[统一验收报告](evidence/macos-runtime-m1/final/acceptance.json)输出 `M1-passed`，检查两组43个有交叉的首方断言，固定 `productionRuntimeReady=false`、`publicExtensionsVerified=false`、`M2Started=false`。它不被产品启动器读取，也不授权执行。

| M1交付条件 | 最终实现和实际证据 |
|---|---|
| 固定工具链和离线构建 | ARM64包包含原生build helper与固定官方esbuild 0.25.5；archive先验SHA-512，签名后字节再进入外层签名profile。只接固定配方、快照、入口；不使用PATH编译器或npm脚本。运行构建阶段不下载。 |
| 真实签名与进程准入 | helper/编译器/宿主Hardened Runtime，准确entitlements、同证书角色、内核父签名约束与每次摘要校验；直接错误父进程、复制宿主和篡改材料拒绝。使用与主应用相同权限的签名首方宿主实际完成流程。 |
| 受保护配置与重启 | 显式新profile、先保护pending保留，再独占创建目录/锁，通过原收据enrollment seam提交；Keychain默认owner ACL，固定服务和UUID账户，不同步、不枚举、不向子进程传私钥。foreign角色读取拒绝；丢失不重置，缓存signer也失效。 |
| 准确Darwin依赖 | 由同一个锁图选择Darwin/arm64。只有匹配的平台元数据可被显式Darwin投影接受，gyp、安装钩子、不明来源和原生文件继续拒绝。archive仍检查SRI、格式、路径、入口与限制；有实际gzip/SRI正负回归。 |
| schema2完整收据 | 沿用原P256 seal，签名覆盖来源/安装ID、完整命令、资源/许可证、清单、配方与策略。新profile不接受旧schema1/VM收据降级。带有效测试签名的资源篡改/路径逃逸/错误配方仍被结构校验拒绝。 |
| 原子安装和明确更新 | 一个注册表、一个安装器；更新必须传入用户确认时的安装快照。独立候选保留旧有效版本，复核中途代次变化，更新保留安装ID、普通偏好与启用选择。卸载同时移除候选。 |
| 崩溃和撤销恢复 | 先持久化 `registry.pending`、推进独立受保护head、再原子发布并同步目录。重启/显式reconcile仅完成head已命名的状态；head仍为旧状态时丢弃未提交文件。失去head不采信磁盘。更新先持久隔离旧代次，停止失败保持停用，精确候选可显式重试；没有自动复活旧实例。 |
| 取消、失败和并发 | 实际编译器已启动后取消，确认退出和scratch删除，旧安装保持；实际编译错误也保持旧安装。应用内共享gate及已登记inode的跨进程build锁；实际双进程互斥和受保护CAS一胜一败。 |

### 产品配置与信任边界

`MacOSBuildProfile`、`MacOSSignedBuildService` 与 `MacOSStoreBuildInstallationService` 都是实际Core实现；生产helper位于 `Sources/KeylaneExtensionBuildHelper`，不是测试fallback。`ProductHost.swift`只把这些真实组件接到固定首方数据，未打包进入应用。普通应用尚未提供新profile设置/安装按钮或运行入口；这是原计划M5的产品切换，不能凭bundle中出现helper就启用安装或执行。

profile来自外层应用签名资源，私有配置/签名key/head位于macOS本机默认owner ACL Keychain槽位，目录与锁inode绑定在独立保护记录中。此次**没有配置Data Protection Keychain access group**；保留#222原有对应存储适配器，但不是本次产品路径的隐式fallback。签名/对端/路径校验与owner ACL组合已在本机真实验证；仍沿用M0信任模型，不承诺任意native RCE、引擎漏洞或VM等强隔离。

macOS构建入口每次验证准确的应用/辅助程序身份；来源/锁/tarball不被当作签名key或授权配置。新的 `prepareAndUpdate(...replacing:)` 与普通安装共用安装器状态机，更新快照失效就停止。`pendingOperation`区分隔离中的事务和普通禁用；显式reconcile可完成已受保护提交，其他不确定状态拒绝。

M1无运行实例，`readiness`固定unavailable、`runCurrent`明确拒绝；因此当前quarantine/revoke仅核对配置。M2接运行时必须把它们接入**唯一**活跃代次/能力/停止确认authority，不得把M1无实例实现作为运行期空操作。没有开放@raycast/api或全部npm兼容，也没有修改API CSV统计。

### 生命周期与交付

来源、摘要、编译、封装和Keychain操作在异步构建路径处理；纯摘要函数及seal不再强制MainActor。构建结束就退出，无保温/后台服务。helper有20秒墙钟监督，固定编译器继承20秒CPU及8MiB单文件限制，产物/metadata逐命令释放；输入32MiB、命令总输出12MiB、协议和诊断均有限额。它们不等同总体RSS硬上限，M4性能预算仍未验收。

本批553项Swift、72项Python检查通过。ARM64 1.0.2/build27 Apple Development DMG的主应用/嵌套工具签名、准确权限、摘要、许可证、文件清单、架构与包布局通过。主应用启用Hardened Runtime时保留已有Apple Events entitlement，避免破坏已有AppleScript能力；移除原资源plist重复音频键后签名成功。相同权限的首方宿主真实启动并通过组合验收，但未向Finder等真实应用发送事件或新授予隐私权限。

首方数据全部清理，未安装Keylane、未推送/合并/发布，远端Checks未运行。包中包含esbuild与Go原许可证，不含测试宿主、测试React、第三方扩展源码、钥匙串数据或VM材料。M1完成指构建/收据/安装事务的代码与首方签名验收，M2–M5和最终集成版安装实测仍按原顺序进行。

### 最终复验

```sh
python3 scripts/check-macos-build-m1.py --report /private/tmp/keylane-m1-acceptance.json
python3 scripts/verify-macos-product-m1.py \
  --helper /path/to/fresh/keylane-extension-build \
  --core-products /path/to/fresh/SwiftPM/Debug \
  --compiler-archive /private/tmp/keylane-m1-esbuild-0.25.5.tgz \
  --report /private/tmp/keylane-m1-product.json
```

组合探针使用当前源码构建的Core对象（或不传core-products重新编译），不是模拟服务。清理意图在任何合成Keychain写入前保存；清理失败保留原始签名恢复应用，不删除其身份。第一批的incomplete报告不单独放行M1，缺签名/清理/任何观察均拒绝。
