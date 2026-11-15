# iPhone 镜像应用：可行性验证 / Feasibility

验证日期：2026-11-15。基线：`origin/dev`，`5b1373b549cbf6f5ca80dce978a781c27a7b7190`。

## 结论与交付边界

**尚未验证可供第三方使用的可靠“发现 + 逐应用启动”机制，暂不实现可用开关或远端应用条目。**

Apple 确认 macOS Tahoe 26+ 的 Spotlight 可以找到 iPhone 上安装的应用并通过 iPhone Mirroring 打开；这不等于第三方应用能查询同一个目录或调用同一个启动入口。本次核对的公开文档、SDK 和本机探针没有建立该契约。这个结论是当前验证范围内的阻塞，**不是证明所有系统版本都不存在这样的机制**。

本次仅提交调查与后续验收方案；未新增设置键、后台采集、搜索结果、硬编码应用清单、猜测 URL scheme 或私有 API 调用。版本与现有中英文界面不变。不把只打开镜像主界面描述为打开指定 iPhone 应用。

English: Spotlight supports remote iPhone apps, but a reliable third-party discovery and per-app launch contract remains unverified. This is a feasibility report, not a completed feature. No toggle, remote collection, or launchable remote results have been added.

## 官方依据

| 来源 | 可以确认的能力 | 不能据此推导的能力 |
| --- | --- | --- |
| [Apple Support：iPhone Mirroring](https://support.apple.com/en-us/120421)，Use Spotlight to find and open iPhone apps | macOS 26+；先配置镜像，再在系统 Spotlight 设置启用 iPhone Apps | 第三方可枚举远端应用、取得设备标识或逐应用启动 URL |
| [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery) | 查询 Spotlight 元数据，支持初始收集与更新通知 | 与 Spotlight UI 的所有搜索提供者等价；其结果必含远端镜像应用 |
| [CSSearchQuery](https://developer.apple.com/documentation/corespotlight/cssearchquery) | 文档描述查询调用应用自己的索引 | 通用的系统 iPhone 应用目录 |
| [NSWorkspace.openApplication](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:)) | 接收应用在文件系统中的 URL，异步报告启动结果 | 接收任意远端 iPhone bundle ID 并路由到镜像 |
| [NSWorkspace.urlForApplication](https://developer.apple.com/documentation/appkit/nsworkspace/urlforapplication(withbundleidentifier:)) | 返回已知 bundle ID 对应的默认应用 URL，或 nil | 枚举远端应用；区分同 bundle ID 的本机与 iPhone 安装 |
| [Running your iOS apps in macOS](https://developer.apple.com/documentation/apple-silicon/running-your-ios-apps-in-macos) | Apple silicon 可以在 Mac 上直接运行 iOS 应用 | 这些本机安装就是远端镜像应用 |

另核对了 Apple 的 [TN3210](https://developer.apple.com/documentation/technotes/tn3210-optimizing-your-app-for-iphone-mirroring)：它指导 iOS 应用适配镜像中的交互，并未提供第三方 Mac 启动器枚举或打开任意远端应用的接口。

本机 macOS SDK 的 `AppKit/NSWorkspace.h`、`CoreSpotlight/CSSearchQuery.h` 也未找到已声明的 iPhone 目录或逐应用镜像启动接口。仅靠关键词检索不能证明接口不存在，故不将其写成绝对否定结论。

## 本机实测与限制

环境：Apple silicon，macOS 27.3 (`26C5035r`)，Xcode SDK 27.2，Swift 6.4.2。**未在 macOS 26 设备上复测。**

1. `/System/Applications/iPhone Mirroring.app` 存在，bundle ID 为 `com.apple.ScreenContinuity`。沙箱外 `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` 能解析此本机应用。它的 `Info.plist` 没有声明 `CFBundleURLTypes`。这仅说明该 plist 无公开声明，不能证明系统内部没有其他入口。
2. 沙箱外 `mdutil -s /` 返回 `Indexing enabled`。公开 `NSMetadataQuery`，本机范围、谓词 `kMDItemContentType == 'com.apple.application-bundle'`，完成收集，得到 7,070 个结果；全部都有现存的 `.app` 文件路径，没有缺失路径或缺失文件。返回属性名中未出现 `iphone`、`remote`、`continuity`。**这仅验证该谓词能找到文件系统应用，不能证明系统没有远端目录或其他类型的索引项。** 数量包含开发目录等内容，不是用户安装应用数量。
3. `/Applications` 与 `~/Applications` 的有限目录检查找到三个 `Wrapper` 目录及其 iTunes 元数据。这是本机 iOS 安装布局的线索；本次未逐个启动验证，也不使用它们冒充远端清单。未保存或提交应用名、设备 ID、账户信息与用户数据库。
4. 沙箱外 CoreDevice 列表报告有已配对且 available 的实体 iPhone。随后通过系统 iPhone Mirroring UI 尝试连接，先显示连接中，最终显示“连接中断”，要求检查附近、开机、最近解锁及蓝牙和 Wi-Fi。**配对可见不代表镜像连接可用。没有完成远端应用发现或逐应用打开实测。** 未修改系统设置、重新配对或权限。
5. 通过 CUA 直接打开 Spotlight 应用失败（Launchd spawn failed，POSIX 162），未完成系统 Spotlight iPhone Apps 开关状态及远端搜索结果的 UI 验证。这是本机验证限制，不是第三方 API 不存在的证据。
6. 沙箱内的同类探针曾报告 Spotlight server disabled、NSWorkspace 解析失败、metadata query 无法启动；沙箱外复测推翻了这些环境性结果。不能把受限环境中的空结果或错误推断为系统未配置、没有设备或没有应用。

公开查询探针可按下面逻辑复现。仅汇总数量，不输出用户应用清单；在正常 GUI 用户会话中运行，并区分启动失败、超时与成功后零结果：

```swift
import AppKit
import Foundation

print(NSWorkspace.shared.urlForApplication(
    withBundleIdentifier: "com.apple.ScreenContinuity") != nil)
let query = NSMetadataQuery()
query.predicate = NSPredicate(
    format: "kMDItemContentType == %@", "com.apple.application-bundle")
query.searchScopes = [NSMetadataQueryLocalComputerScope]
var finished = false
let token = NotificationCenter.default.addObserver(
    forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
) { _ in
    print("completed count=\(query.resultCount)")
    finished = true
}
if query.start() {
    let deadline = Date().addingTimeInterval(5)
    while !finished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if !finished { print("timeout; availability unknown") }
} else {
    print("query could not start; availability unknown")
}
query.stop()
NotificationCenter.default.removeObserver(token)
```

## 现有架构与最小可行方案

`KeylaneCore/LauncherCatalog.swift` 的 `CatalogApplication` 以本机 `url.path` 为 ID，`ApplicationCatalog.scan` 扫描 `.app` 文件并规范化路径去重。`ApplicationDiscovery` 负责文件监听和取消过期扫描；设置通过 `ApplicationPreferences` 与 `ApplicationSettingsCatalog` 展示本机路径。`Model.launch` 使用 NSWorkspace 打开本机 URL。这套架构未提供设备或远端目标语义。

本机 iOS 安装仍属于本机文件系统应用；远端镜像应用运行在 iPhone。名称、bundle ID 相同不能据此合并二者，也不能给远端条目合成本机路径、Finder 动作、卸载或自动退出能力。

**现在可用的最小方案**：继续通过现有应用目录打开系统 iPhone Mirroring，再由用户在系统镜像界面操作；连接可用且系统 iPhone Apps 已开启时，也可按 Apple 文档直接使用 Spotlight。当前设备连接中断，因此这只是系统提供的使用路径，本次没有验证其完整成功链路。它不满足 Keylane 内显示并逐个启动远端应用的需求，不应标记该功能完成。

重新进入实现前，先取得 Apple 公开、支持第三方的目录与启动契约，或验证系统提供的稳定文件代理确实可通过公开 NSWorkspace 接口逐应用打开。需要同时证明来源、稳定身份与启动能力；仅有名称、图标、缓存记录或能打开镜像主界面均不足。优先向 Apple Developer Technical Support 请求明确接口和支持范围，不将系统私有缓存、反编译出的 XPC 协议或 Spotlight UI 自动化加入生产实现。

## 后续实现与测试门槛（尚未实现）

- 默认关闭并持久化开关，复用应用扩展的设置组件、搜索锚点、导入导出和既有中英文翻译。开关名称可为“显示 iPhone 应用 / Show iPhone Apps”。
- 分开表示用户偏好与运行时能力；不支持、尚未配置、连接不可用和未知错误分别解释。不能仅检查 OS 版本或镜像 app 存在就标记可用。项目当前最低 macOS 26，但 provider 能力仍需独立检查。
- 使用带来源的身份：本机路径与远端设备身份加应用身份分开；具体字段必须来自验证后的系统契约，不能自造设备 ID。同名不同源保留；同一远端目标的重复通知合并。
- 保留现有搜索、列表与命令登记架构；远端专属行为由已验证 provider 提供。收藏、忽略、禁用、别名、快捷键都使用稳定目标身份，不能借用临时文件路径。
- 关闭时先撤销监听/查询并使旧 generation 失效，再移除内存列表、搜索快照、命令、快捷键和缓存条目；关闭期间零采集，迟到回调不能重新显示。重新启动进程仍遵守关闭状态。
- 自动化覆盖身份稳定性、同名本机/远端区分、多设备、重复项、过滤/忽略与收藏、开关持久化、导入设置、快速切换和迟到回调、应用扩展禁用、版本不支持、未配置、连接中断、权限或查询错误。用 fake provider 测试生命周期，不能把模拟成功称为系统实测。
- 对启动失败清楚提示，不记录成功使用次数；按系统契约处理异步结果。系统接受请求不等于目标 iPhone 应用已显示。
- 实机覆盖 macOS 26 与更新版本：首次配置、Spotlight iPhone Apps 开关、附近锁定 iPhone、镜像认证、从 Keylane 打开指定应用、退出/重连、设备切换、远端卸载与重装、本机同名 iOS 应用共存，以及关闭后无采集和无残留。

上述测试没有新增到当前代码，因为尚无真实 provider 与产品行为可验证；此处是实现门槛，不能计入已通过的功能测试。

## 与 #108 的关系

核对时 [PR #108](https://github.com/Acckion/Keylane/pull/108) 仍 OPEN，分支 `fix/application-favorites-consistency`。它修改 `ApplicationResultActions.swift`、`BuiltinLauncherModules.swift`、`Launcher.swift`、`main.swift` 等应用命令路径。本次只新增本文件，不修改这些共享文件，也不依赖或合并 #108。未来实现前须重新检查其合并状态与身份、收藏逻辑。

## 本次验证结果

| 检查 | 结果 |
| --- | --- |
| `python3 scripts/check-version.py` | PASS，1.0.2 / build 27，未改版本 |
| ReleaseTests unittest discovery | PASS，6 项 |
| Python compileall 与全部 shell 脚本 `bash -n` | PASS |
| `swift test --scratch-path .build-current --disable-sandbox` | PASS，152 项 XCTest，0 失败；构建 debug 产品 |
| `bash scripts/verify-application-discovery.sh` | PASS，现有本机目录发现集成测试，非远端镜像测试 |
| `KEYLANE_ALLOW_ADHOC=1 bash scripts/package.sh` | PASS，arm64 Release DMG，临时签名，未公证 |
| `python3 scripts/verify-package.py dist/Keylane-1.0.2-macos-arm64.dmg` | PASS，布局、元数据、许可证、文件清单、架构、签名 |

Swift 测试、目录监听集成测试与打包曾在执行环境沙箱内分别因 pasteboard 服务、FSEvents 及 dsymutil 受限失败；在同一检出、代码未变的情况下，正常系统访问环境下重跑通过。未删除或跳过测试。编译缓存显式放在临时目录。本次未安装构建产物，未创建发布，也未声称完成 iPhone 镜像功能的实机验收。CI 状态以 PR 的 Checks 为准。
