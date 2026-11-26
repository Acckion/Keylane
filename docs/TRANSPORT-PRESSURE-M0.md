# M0 第五批：异常传输与有界内存压力

日期：2026-11-22；本地前序提交 `310c2af5`，已核对远端 dev 仍为 `5c6d6aa4f81fbf53684d3b9059af1376bbc87ff0`。继续严格隔离目标；本分支待合并，M1未开始，不接通第三方执行。

## 已修复的缺口

第四批原生父进程将“没有收到新消息就EOF”和“消息头收到1至3字节后EOF”都表示为nil；后者没有明确报告协议失败。helper在读取截断回复时则返回普通拒绝字符串，JS还能继续尝试使用已经坏掉的通道。

本批增加抽出的原生 `M0FrameChannel`：正常边界EOF、完整消息与非法消息分开表示。读取错误、部分头部、部分正文、零长度和超过4096字节的声明都明确拒绝；先验证长度，再分配正文。协议失败时关闭绑定并终止本次helper，返回71。helper遇到回复截断、非法长度或非法UTF-8同样立即退出71，不尝试恢复该通道。业务请求被拒绝仍可在连接额度内继续，不与传输失败混淆。

源码仍只位于Tests/scripts，没有修改产品启动器、安装器、设置、签名权利或兼容CSV。

## 实验中的内存监督

原生父进程通过公开 `proc_pidinfo` 每20毫秒采样**本次helper**的resident size。超过64MiB则终止该进程，观测失败也拒绝继续。监测线程停止并join之后才由父进程waitpid回收，避免监测线程对已复用PID发送信号。helper本身仍保留独立FD3 EOF监督，父进程期限仍是8秒。

这是采样式实验保护，**不是64MiB硬上限**。进程可以在两个样本之间超调；没有验证内核强制内存额度、整个进程树预算、引擎逃逸或系统低内存压力。压力脚本仅保留最多128MiB的合成TypedArray内容并主动触页，不尝试耗尽系统内存。128MiB指脚本测试分配量，不包含引擎本身。

另编译仅观察、不执行内存终止的签名父进程对照。脚本、helper、证书、阈值和采样相同；对照只能在Tests里编译，不能由JS、manifest或正常父进程运行参数选中。不以“脚本自己抛错/自己退出”冒充资源保护成功。

## 实际验证

[第五批去标识报告](evidence/macos-runtime-m0/transport-pressure-probe.json)：19项签名进程子检查通过，整体 **incomplete / 退出3**。

| 检查 | 实际证据 |
|---|---|
| 合法分段请求 | 原生首方peer逐字节发送头部，正常读取合成值；正对照经过同一解析器和broker |
| 请求零／超大长度 | 拒绝；不执行业务请求、不按声明大小分配内存 |
| 请求头截断1／2／3字节、正文截断 | 父进程明确报协议错误71，原生故障peer被终止；请求计数0 |
| 回复零／超大长度、头／正文截断、非法UTF-8 | helper退出71，没有返回JS结果 |
| 原生RPC阻塞时只终止父进程 | 先收到父进程“回复已扣住”的原生阶段事件，再SIGKILL父进程；helper因FD3 EOF退出，没有JS结果 |
| 原生RPC阻塞直到期限 | 父进程8秒期限退出74，helper退出；不依赖JS线程响应 |
| 输出32768／32769字节 | 边界值成功，超出返回71，不输出超限正文 |
| 有界内存压力 | 正常候选在采样峰值64.9MiB终止；仅观察对照达到136.9MiB后正常返回32块完成结果 |
| 清理 | 每例确认本轮唯一临时路径下helper退出；不依靠全局killall，失败清理不计通过 |

上述内存值是本次合成运行观察值，不是最大值保证、p95或产品扩展资源预算。没有运行真实第三方扩展。

未签名原生解析器测试另外验证正常EOF、各类截断、4096字节边界、4097字节拒绝和无效FD读取错误；正常CI只运行这些合成测试与报告判定测试，不运行签名负对照。

[第四批17项复测](evidence/macos-runtime-m0/broker-round5.json)与[第三批18项复测](evidence/macos-runtime-m0/restricted-js-round5.json)均通过观察子集，仍返回incomplete；旧Node两批blocked基线未删除或改判。所有签名在运行前后核验，临时进程和材料确认清理后才写报告。

## 真实收据准入核对

本批只读核对了 #222 草稿 `c7b419771a5196a65bd8894daa6c63fd3ce74f43`，当前仍open/draft，未修改。当前固定dev基线不包含下列商店收据类型；不能把测试seal或复制的签名父进程当作它们的替代权威。

| 草稿中的边界 | macOS候选接入必须保留的不变量 |
|---|---|
| `RaycastStoreProtectedReceiptState` | 受保护状态和registry独立；原子CAS、回滚／删除检测；缺少配置时拒绝执行，不能自采纳可编辑JSON |
| `RaycastStoreDiskRegistry.withCurrentRun` | 在锁定的当前安装快照中同时验证启用状态、generation、制品和命令；不能只在启动前读取一次 |
| `RaycastStoreSignedInstallationService.admission` | 安装ID、命令entry、已验证制品、recipe/runtime和能力来自宿主权威，不接受脚本自报；生成本次运行lease |
| `StoreRuntimeBridge` / ticket | 每次启动验证实际artifact bytes及runtime摘要；持续复核lease；构建generation0与活动generation分开 |
| 旧guest类型 | 后续提取与VM无关的契约；不能把名称替换或删除guard当作新macOS隔离已验收 |

**本批仍未接入这些生产权威。** 下一步需用第一方签名制品和独立权威的安装夹具验证真实摘要／收据／当前代次链，再决定与草稿集成方式；不得仅新增另一套“声称已验证”的JSON记录。签名父约束只验证启动者，不证明它此次有权执行哪一个安装。

## 尚未达成的条件

- 实际安装收据／注册表准入与替换、卸载、宿主重启的跨进程持续撤权。
- 共享容器、Keychain及其他宿主服务边界；内存分区不等于整个helper容器净化。
- 真正的内存强制上限、并发／CPU／输出压力、生产监督器与资源预算。
- 固定版本no-view／view／storage样例及React、Node依赖兼容差异；无Node回退，不修改覆盖计数。

无VM新依赖，无受信扩展模式切换，M1–M5保持未开始。没有因19项通过而提供“生产通过”出口。

## 复验

```sh
python3 scripts/verify-macos-transport-m0.py --report /private/tmp/keylane-transport-report.json
python3 scripts/verify-macos-broker-m0.py --report /private/tmp/keylane-broker-report.json
python3 scripts/verify-macos-restricted-js-m0.py --report /private/tmp/keylane-restricted-report.json
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
```

需要本机有效Apple Development身份，无ad-hoc回退；报告路径必须不存在。2表示观察失败，3表示子集通过但M0仍缺项；环境或编译错误也不是通过。仅首方临时夹具，不安装、不读取真实剪贴板或用户文件。

源码：[帧解析](../Tests/ExtensionPrototype/MacOSRuntimeM0/Broker/FrameChannel.swift)、[首方原生故障peer](../Tests/ExtensionPrototype/MacOSRuntimeM0/Transport/RawPeer.m)、[实验内存监测](../Tests/ExtensionPrototype/MacOSRuntimeM0/Transport/MemoryGuard.c)。

交付检查：421项Swift、54项Python测试通过；版本、脚本编译、Shell语法、本地文档链接和源码差异检查通过。固定基线的ARM64 Debug 1.0.2/build27测试包用本机Apple Development签名，包布局／元数据／许可证／资源清单／架构／签名检查通过；探针不在产品包中。未安装、推送、发布或运行远端CI；包通过不代表M0或真实扩展验收完成。
