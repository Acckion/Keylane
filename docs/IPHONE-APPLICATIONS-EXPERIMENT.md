# iPhone 应用调查与备选实验草稿

本分支从 `origin/dev` 的 `fe60d79` 开始，随后整合并保留并行自动退出设置更新 `872f4d3`，更新旧调查草稿 [#109](https://github.com/Acckion/Keylane/pull/109) 的证据。**不合并、不发布。devicectl 仅是依赖 Xcode 和开发者模式的备选实验，不是最终产品方案。优先目标仍是无需上述依赖的简单方案；本轮尚未验证这样的第三方逐应用启动入口。**

## 无需 Xcode 的优先调查

| 候选 | 证据及判断 |
| --- | --- |
| 系统 Spotlight | [Apple 支持文档](https://support.apple.com/en-us/120421) 明确 macOS 26+ 可搜索手机应用并通过镜像打开。文档描述系统 UI，没有给第三方提供逐 bundle ID 调用契约。用户禁止前台搜索、点击和键盘自动化，本分支未模拟这些操作。 |
| URL scheme／AppleScript | 本机 iPhone Mirroring 的 Info.plist 没有 `CFBundleURLTypes`、`NSUserActivityTypes`、`NSAppleScriptEnabled`，包中没有 sdef/scriptSuite。可执行文件存在 `application:openURLs:` 符号，但符号存在并不证明公开 URL 格式、权限或第三方支持。未构造猜测的私有 URL、启动载荷或 Apple Events。 |
| 公开 NSWorkspace／LaunchServices | 本机 macOS 27.2 SDK 的公开 AppKit 和 LaunchServices 头文件未找到 iPhone Mirroring 专用逐应用入口。普通应用打开 API 无法仅凭 bundle ID 区分 Mac 和手机同 ID 应用。占位包不能当成本机可执行包打开；未复用私有配置字段。这个有界搜索不能证明所有公共途径都不存在。 |
| 通用链接、应用 URL | [Apple 开发文档](https://developer.apple.com/documentation/Xcode/defining-a-custom-url-scheme-for-your-app) 描述应用注册并接收 URL，没有通用的远端 iPhone 设备选择参数；同 scheme 多处理者的选择也不确定。不能把 Mac 上 open URL 的成功当成手机已启动。 |
| Handoff | [Apple 开发文档](https://developer.apple.com/documentation/foundation/implementing-handoff-in-your-app) 要求跨平台应用共享 Team ID 并实现相应 activity。不能让 Keylane 任意启动其他开发者的手机应用。 |
| 快捷指令 | 本机 `shortcuts help run` 只有名称、输入、输出与类型，没有远端设备参数。[Apple 文档](https://support.apple.com/en-gb/guide/shortcuts-mac/apd163eb9f95/mac) 描述同步后在目标设备自行运行，不能推断 Mac 命令可远程执行手机上的「打开 App」。未读取或运行用户快捷指令，也未创建自动化。 |
| Apple 私有镜像服务 | 用户此前已验证直接镜像启动存在私有 entitlement 边界。只保留调查结论，不调用或仿造授权、不重签系统应用、不注入系统进程、不绕过安全检查。 |

当前可提供的无开发环境路径是用户手动使用系统 Spotlight／镜像；这不是符合本任务限制的自动逐应用实现，因此没有将它伪装成已完成产品方案。下一步应向 Apple DTS 确认第三方启动契约，或等待可验证的公共入口。没有安装任何替代工具。

## 已实现的备选草稿

设置位于「应用程序 → iPhone 应用（实验性）」，默认关闭，明确标示备选定位和依赖。复用 SettingsGroup、SettingsRow、SettingsPicker 与 CommandSettingsList；加入设置搜索锚点与分组快捷键列表。

- 发现只读取 `~/Library/Daemon Containers`／`Containers` 的容器元数据，用 `MCMMetadataIdentifier == com.apple.appplaceholdersyncd` 定位。支持容器内 `Data/Library/Caches` 与 `Library/Caches`；匹配 `Placeholders*.noindex`，不固定 UUID 或 v6。读取 `.app` 的 Info.plist，仅以 NSDictionary/NSString 安全解归档取得 `NSiPhoneMirroringLaunchPayload.bundleID`，校验标识符并去重。缺失、损坏、版本和目录变化可手动刷新；不永久缓存目录路径，也不监控整个用户 Library。
- 目录属于系统内部实现，Apple 可能修改或限制访问；缓存不保证完整、新鲜，可能来自另一台手机。不能据此判断所选设备当前安装状态，失败时须由设备启动返回错误。
- 手机使用独立 `iphone:<bundleID>` 身份，Mac 保持路径与 `app:<path>`。别名、收藏和热键分别存储，关闭仅清除手机内存目录及禁止旧入口，不重绑到 Mac。Mac 扫描额外排除镜像占位包，即使用户把缓存目录加入自定义扫描范围。
- 手机动作只提供打开、收藏和设置；不进入 Mac 卸载选择、Finder、参数启动、退出、重启或自动退出。手机快捷键只尝试启动，不模拟 Mac 的隐藏／显示切换。
- 设备枚举兼容新 `properties` 与旧字段，只接受已配对的实体 iPhone。仅一台时可自动选择；多台必须手动指定；已选设备消失不回退其他手机。每次启动重新枚举并检查可用状态。
- 后台串行执行 `/usr/bin/xcrun devicectl`，参数数组、不经 shell、不继承 `DEVICECTL_CHILD_*`。设备枚举 10 秒、启动 30 秒，外层另设超时、TERM 与 KILL 回收；临时 JSON 私有目录用后删除。不采集手机应用输出、截图、文档或私人内容。
- 枚举完成后重查开关及代次，再准入启动。关闭或模块停止丢弃旧发现结果；已发送给手机的启动请求无法撤销。需要现有 Xcode 及其可用开发组件、配对、开发者模式。Keylane 不启用或修复这些设置，也不自动连接镜像。macOS 最低版本为 26，较旧系统无法运行本项目。
- 启动只报告工具请求成功，不保证画面可见。设备离线、锁定、缺少开发环境、目标应用不在此手机、超时和 JSON 不兼容均保留失败反馈。锁定手机通常需要用户先手动连接 iPhone 镜像；不能承诺绕过设备锁。

## 证据与验证

2026-11-15，本机只读扫描复验 147 个占位包。Swift 实现直接扫描同一系统目录得到 `READ_ONLY_CATALOG_COUNT=147` 与 `VALID_IDENTITIES=true`；不提交应用清单、设备名称、UUID、序列号或原始设备 JSON。

本轮 `devicectl list devices` 正常系统访问下成功，检测到两台登记 iPhone 均 unavailable，另有手表被过滤。沙箱内枚举曾超时。没有猜选手机或发起真实应用启动。本任务此前已验证锁定手机且镜像连接时 Shazam 启动成功；该证据来自委派上下文，不算本轮再次验收。镜像未连接曾返回 Locked，不能从开发工具的单次成功推导普通第三方无开发模式也能成功。

自动化：157 项 Swift XCTest 在正常系统访问环境全部通过（沙箱内既有的两项独立命名剪贴板测试共 8 个断言失败；没有修改这些测试）。新增 3 项单元用例覆盖归档与标识符校验、目录版本/UUID 变化、缓存删除与损坏、占位包隔离、新旧设备 JSON、非 iPhone 过滤、多设备与失效选择。AppKit 合成集成验证同名 Mac／手机身份、别名、收藏、关闭后的结果及旧热键、允许动作、参数数组、超时强制回收与过期扫描丢弃。版本检查、6 项 ReleaseTests 与脚本语法检查通过。arm64 Release 临时签名 DMG 构建与 `verify-package.py`（文件清单、资源、版本、最低系统、架构与签名）通过；未安装、未公证、未发布。沙箱内 dsymutil 和磁盘映像挂载曾受限，正常系统访问下重跑通过。可复跑：

```sh
swift test --scratch-path .build-current --disable-sandbox
bash scripts/verify-iphone-applications.sh
python3 scripts/check-version.py
python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'
KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh
python3 scripts/verify-package.py
```

集成夹具仅使用独立偏好域、临时 home、合成设备与应用，替换设备命令执行器；没有运行用户手机应用、注册全局快捷键、操作前台 UI、请求权限或更改安全设置。真实系统服务访问被沙箱阻止时，需在正常系统访问环境运行；不得把沙箱失败删改成成功。

未完成：无需 Xcode／开发者模式的第三方逐应用入口；手机实际启动的本轮成功复验；多台实体设备切换及缓存归属；安装版设置搜索、深浅色、布局和实体热键；macOS 26 真机兼容性。草稿不满足最终产品合入条件。
