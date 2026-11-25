# M0 第四批：有界 broker 与调用代次

日期：2026-11-22；固定集成基线 dev `5c6d6aa4f81fbf53684d3b9059af1376bbc87ff0`，保留 Office/OCR、设置图标与 Python 缓存忽略规则。继续用户确认的严格隔离目标，不恢复 VM、不转受信扩展模式。

## 结论与边界

给上一批受限 JS 候选增加第一方最小 broker。17 项签名双进程子检查通过，整体仍为 **incomplete（退出3）**。完整 Node 的两轮 blocked 结果不变，未进入 M1，没有启用公开扩展、商店执行或修改 #222。

**安装准入的根仍是测试夹具。** 签名原生父进程创建合成安装记录，按测试场景选择记录、核对合成 seal／generation 后发放绑定。seal 是测试常量的相等比较，既不是实际制品的摘要验证，也不是 Store 收据证明。测试控制器可以调用真实测试父进程并选择场景；内核父签名约束无法独自阻止这种调用。因此 `wrongSealRejectedBeforeSpawn` 仅证明守卫拒绝不匹配夹具值，不能写成“真实安装身份验证已完成”。

没有把 JS 请求中自报的 owner、路径或命名空间变成权限。没有产品数据库、磁盘存储、网络、文件能力、Keychain 或真实用户数据；仅使用测试进程内的两个合成字典。代码只在 Tests／scripts 中，未接产品 Sources、注册表、安装器或运行入口。

## 通道与授权模型

- 父进程以不透明原生 Binding 绑定安装、generation 和随机 epoch；脚本从未获得 Binding，也不能在请求中选择其他安装。关闭／替换／卸载／撤权后旧绑定失效，关再开不会恢复旧 epoch。
- 专用继承 socket FD4 承载 RPC，FD3 仍只做父存活监督。`POSIX_SPAWN_CLOEXEC_DEFAULT` 配合显式 stdio、FD3、FD4 继承，不交出通用原生对象或文件描述符接口。
- JS 只得到 `__m0Request(string) -> string`，没有 JSExport、ObjC／FFI、任意原生方法或路径接口。帧是4字节网络序长度加 JSON，正文最多4096字节；v1仅允许 `id/op/key/value`。额外 owner 等字段拒绝。
- 请求 ID 必须是非布尔、精确安全范围内的正整数，按绑定单调递增；原生 work／reply 一次性消费，后来的请求使旧 work／reply 失效。合法性失败也消耗连接额度。
- 仅提供 `storage.get/set`；键为最多64字节的受限ASCII标识符，不接受路径；值最多512 UTF-8字节。每连接最多32帧，包括拒绝的帧。原生父进程还有8秒期限；这只是第一方实验限额，不是产品 SLA。
- **准备、执行、披露三次核对**：执行前重查绑定、当前请求和 grant；返回前再次核对代次及关闭状态。异步窗口通过原生夹具在阶段之间注入撤销，避免仅在 JS 提交时检查一次。
- 这份 `M0Broker` 限定于父进程的串行原生循环，不是线程安全的产品服务。产品接入须定义串行执行域，并把安装事务、命令运行域、权限状态与真正的认证通道作为唯一权威来源。

撤权不会撤回已经披露的内容，也不会回滚撤权前已完成的写入。执行前撤销写权限保证不写；执行后关闭保证晚到回复不披露，但已提交的写入仍保留。测试明确覆盖这两种情况，不能让调用者把拒绝回复当成“没有发生任何副作用”。

## 实测与对照

[去标识报告](evidence/macos-runtime-m0/broker-probe.json)由真实签名双进程实验生成，不含本机身份、PID、路径、源代码或用户内容。

| 检查 | 实际结果及限制 |
|---|---|
| A/B各自读取、A写入 | 各自读到不同合成值，A写入后B保持不变；仅证明本次内存分区 |
| 伪造 owner、请求重放 | 拒绝，回复不包含B正文；旧ID无法重新执行 |
| 非法JSON、布尔ID、路径、超限输入 | 拒绝；原始帧截断／损坏注入未覆盖 |
| 准备后关再开、替换、卸载 | 执行拒绝；旧绑定后续请求同样拒绝 |
| 已读取后撤读权限、关闭绑定 | 结果披露拒绝，脚本未收到已读取的合成正文 |
| 合成 seal不匹配 | 父进程不启动helper；不是实际收据验证 |
| 同证书错误identifier父进程 | helper被内核启动约束终止，脚本未执行 |
| 第33帧 | 原生父进程终止helper；前32帧计数准确 |
| JS死循环 | 父进程8秒原生期限退出，helper通过FD3 EOF退出，不靠JS响应 |
| 测试进程清理 | 每轮按本轮唯一临时可执行路径确认helper退出；有残留则清理并报错，不计通过 |

另外，未签名原生状态机测试覆盖：错误 generation、work/reply重放、后发请求废弃旧请求、执行前撤销写权限不落地、执行后关闭不回滚写入、32次非法流量耗尽额度。它们是合成状态机回归，与上述签名进程证据分开记录。

[上一批18项受限JS正／负对照复测](evidence/macos-runtime-m0/restricted-js-round4.json)仍为 incomplete：新 broker 仅通过编译宏加入本批helper，没有改变不带宏的旧候选。测试控制器的精确路径/PID核对只服务首方夹具清理，不是未知恶意后代的生产监督器。

## 剩余 M0 工作

1. 将准入根换成实际安装收据／不可变制品与当前 Registry 代次，验证复制真父进程、伪造安装、替换期间旧连接和跨运行请求；本批刻意未接这条生产路径。
2. 注入原始传输截断／畸形帧、宿主异常退出、内存与输出压力；扩展资源预算尚未验收。
3. 明确共享helper容器、Keychain及其他宿主服务边界；内存字典隔离不等于整台机器的数据隔离。
4. 固定版本的 no-view／view／storage 编译样例与 React／Node 依赖差异实验。受限候选尚无 Node、模块加载、React和公开Raycast API，不更新兼容CSV实现数量，不做Node回退。

需根据这些证据才能决定产品引擎与兼容范围。M1–M5保持未开始。

## 复验与交付

```sh
python3 scripts/verify-macos-broker-m0.py --report /private/tmp/keylane-broker-report.json
python3 scripts/verify-macos-restricted-js-m0.py --report /private/tmp/keylane-restricted-report.json
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
```

报告路径必须不存在；脚本使用现有有效 Apple Development 身份，无 ad-hoc 回退，不导出证书、不安装。2代表观察到失败，3代表该子集通过但M0仍缺项；没有生产通过出口。

源码：[串行授权夹具](../Tests/ExtensionPrototype/MacOSRuntimeM0/Broker/Authority.swift)、[签名父进程](../Tests/ExtensionPrototype/MacOSRuntimeM0/Broker/Parent.swift)、[状态机测试](../Tests/ExtensionPrototype/MacOSRuntimeM0/Broker/AuthorityTests.swift)。

本批交付检查：421项Swift测试、50项Python发布／夹具测试、版本检查、脚本编译与源码差异检查通过。本基线ARM64 Debug 1.0.2/build27测试DMG使用本机Apple Development签名，包布局、元数据、许可证、资源清单、架构与签名检查通过。探针不在产品包中，因此包通过不能视为扩展隔离验收。没有安装、推送或发布，也未运行远端CI。
