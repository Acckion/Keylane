# M0 第六批：复用签名收据与当前安装代次

日期：2026-11-22；前序提交 `ea1980b6`，远端dev仍为 `5c6d6aa4f81fbf53684d3b9059af1376bbc87ff0`。#222仍为open/draft、头 `c7b419771a5196a65bd8894daa6c63fd3ce74f43`，本批未修改。保持严格隔离，本分支待合并，M1未开始。

## 实现范围

第四批broker的seal来自常量比较，第五批已明确它不能证明签名制品身份。本批把#222的**原始收据／注册表算法**接到受限JS首方样例：不是再定义一套收据JSON，不修改草稿源码，不删除旧VM守卫来放行。

探针从本仓库固定Git对象导出完整 `Sources/KeylaneCore`，原样编译为临时静态模块。源提交与关键文件SHA-256写入报告。缺少该提交时失败，不下载可变分支、不回退当前dev，也不把这些草稿类型复制进产品Sources。`@testable`仅用于首方夹具构造内部上下文，没有公开给扩展。

原样复用的算法：

- `RaycastStoreSnapshot` / `SourcePackage` / `BuildProject` 验证自建源码清单与Git blob摘要，不访问公共扩展源码或网络。
- `RaycastStoreArtifactSeal` 验证P256签名、安装ID、固定来源revision、recipe/runtime、命令清单和内层artifact摘要。
- `RaycastStoreProtectedReceiptState` 与 `DiskRegistry` 使用独立CAS头验证磁盘状态，并通过实际prepare、activate、validate及withCurrentRun取得当前安装。
- `StoreGuestRunTicket` 只消费一次；运行时每次操作仍检查同一live lease，不把签名收据当成永久授权。

第一方字节是固定纯JS样例，没有调用构建服务、npm、Node或VM。`runtimeDigest`来自本次实际helper文件。父进程只执行从已验证收据提取的这份JS，不把stdin的source字符串当作代码。stdin只供测试控制器选择固定正负场景。

## 授权根的准确边界

**这不是产品安装准入完成。** P256私钥仅在本次父进程内临时生成，公钥来自该独立首方夹具，而不是制品；私钥不导出、不提交。受保护存储提供方仍是内存CAS夹具，磁盘注册表仅在本次唯一临时目录内。没有登记产品签名身份、系统可信存储或真实用户安装，没有证明整次进程重启后的持久授权。

本探针可以创建自己的全新首方测试根；不能以“复制这个真实签名测试父进程仍能运行固定样例”推断它能验证产品安装权限。产品必须接入独立、不可由启动请求自登记的profile／公钥／受保护存储，并验证复制宿主、替换路径和跨运行连接。普通Keylane和#222的运行配置仍未启用。

## 持续撤权与强制停止

broker的存储命名空间、generation、摘要和读写能力现在来自原生的已验证ticket。Binding持有live检查；准备、执行和披露阶段均复查。只要观察到外部lease失效，就永久撤销本Binding，即使错误的回调后来返回true也不能恢复；新调用必须取得新Binding。

独立首方Trust提供方实现草稿的quarantine/revoke契约：先递增撤权水位、同步失效旧lease，再SIGKILL本次尚未回收的helper，通过公开waitid/WNOWAIT确认它已退出，之后才允许注册表写入／重新启用。最终waitpid仍由父进程唯一负责，内存监测线程在回收前停止，避免PID复用。

这是对**本候选中没有子进程创建能力的单个helper**的停止证明，不是任意Node恶意后代的监督实现。没有扫描未知进程树或全局killall。关再开得到新代次，旧ticket与旧进程不会恢复；替换通过卸载旧安装、验证并激活新安装模拟，未新增产品更新事务。

执行前禁用阻止业务效果；读取后禁用扣住正文，并确认helper已经退出。已经提交的写入仍不回滚，沿用第四批语义。

## 实测与问题修正

[签名双进程报告](evidence/macos-runtime-m0/receipt-bridge-probe.json)的20项子检查通过，整体仍为incomplete（退出3）。覆盖：合法首方制品、脚本注入拒绝、签名／内层摘要篡改、错误公钥／runtime／安装ID／命令／revision／grant、磁盘回滚、保护头删除、票据重放、执行前后禁用、关再开、卸载、替换、CAS失败和进程清理。初轮的两项断言修正严格匹配草稿现有错误：回滚跨过两个头时为registryMismatch，CAS冲突被注册表包装为anchor；没有改动算法或把任意异常都算拒绝通过。CAS失败还验证旧水位无法重新mint lease。

复测发现第五批内存采样的一处退出竞态：task已经销毁时，BSD zombie状态未必同步可见。改用waitid/WNOWAIT的正向内核退出证据；缺少task样本时最多重查退出状态两次，每次间隔10毫秒。只有确认该子进程已退出才正常结束，仍存活而无法观测则终止并报失败，不吞掉观测错误。采样仍不是硬内存上限。

新增原生测试执行50轮退出交错，并编译强制采样失败的反对照：已退出子进程不误报；无法采样且仍存活的子进程必须被终止、观测必须记失败；另外确认强制停止不会抢先回收父进程的waitpid。负对照宏仅存在Tests，不可由JS或正常运行参数选择。

## 尚未完成

- 产品独立可信配置、持久受保护后端、跨进程原子性与宿主重启后的撤权水位；当前CAS不代表Keychain或其他持久提供方验收。
- 真实不可变制品部署／路径替换与复制产品宿主的准入，完整命令运行域和连接认证。
- 容器残留、Keychain及其他宿主服务、内存硬额度与生产资源预算。
- no-view／view／storage实际编译样例、React/Node依赖兼容差异；不更新兼容CSV、不做Node回退。

M0整体仍为incomplete；旧Node blocked基线保留，M1–M5未开始。没有启用商店第三方执行，没有切换受信模式或增加VM依赖。

## 复验

```sh
python3 scripts/verify-macos-receipt-m0.py --report /private/tmp/keylane-receipt-report.json
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
```

需要固定Git对象 `c7b419771a5196a65bd8894daa6c63fd3ce74f43` 和有效本机Apple Development身份。缺失时停止，不采用ad-hoc或另一个源码版本。报告路径必须不存在。仅首方临时制品；正常CI运行判定／状态机／原生监督测试，不自动下载草稿或运行签名探针。退出2=观察失败，3=子集通过但整体缺项，没有生产批准出口。

源码：[收据桥接夹具](../Tests/ExtensionPrototype/MacOSRuntimeM0/Receipt/Gate.swift)、[一次性绑定](../Tests/ExtensionPrototype/MacOSRuntimeM0/Broker/Authority.swift)、[非回收式停止](../Tests/ExtensionPrototype/MacOSRuntimeM0/Transport/MemoryGuard.c)。

[17项broker](evidence/macos-runtime-m0/broker-round6.json)、[19项异常传输／压力](evidence/macos-runtime-m0/transport-round6.json)和[18项受限JS](evidence/macos-runtime-m0/restricted-js-round6.json)在本批最终源码上复测，子集通过且均为incomplete。旧Node报告原样保留，本批未重复运行或改变其判定。421项产品Swift测试与59项Python／夹具测试通过；原生正常／采样失败反对照各运行50轮退出交错。

交付检查：版本／脚本编译／Shell语法／文档链接／源码差异检查通过。ARM64 Debug 1.0.2/build27测试DMG使用本机Apple Development签名，布局、元数据、许可证、资源清单、架构和签名校验通过；探针不在产品包中，不代表扩展运行可发布。未安装、推送、发布或运行远端CI。
