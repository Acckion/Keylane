# 扩展协议与隔离原型

基线 `84044d5`。本轮范围是可信本地代码、协议与隔离验证。测试入口只运行仓库内审阅过的合成样本。架构师批准的下一阶段以安全原型验收为前提。 [评审](codex://threads/01a1cb7d-bfbf-7661-a87f-55264e4ae416)

## 协议

`ExtensionPrototypeSession` 对换行分隔的 UTF-8 JSON 做有界解帧。每条消息带宿主签发的会话 UUID 和安装代次。首帧协商版本，当前为 1。请求 ID 单调递增，乱序或重放的请求关闭会话。旧会话或安装代次的帧被丢弃，同时计入预算。取消清理未完成的帧并使后续消息失效。

授权来自创建会话时宿主传入的能力集合。原型仅提供 `echo`，并通过伪造扩展身份的测试验证 worker 自报的身份无法扩大授权。每帧 16 KiB、每个一秒窗口 32 条、每会话 128 条。窗口和额度是原型参数。每个有效帧按顺序立即提交回复，后续坏帧终止会话，半帧 EOF 视为错误。复审后用匿名管道将 Swift broker 和隔离的 Node 测试进程双向联调，日志由独立的 stderr 管道收集。握手、授权、旧代次过滤、半帧 EOF、握手超时及回复背压通过本机测试。启动器动态命令接入仍待验证。

## 本机实测

环境为 Apple Silicon、macOS 27.3、Node 25.9.0。Node 版本是本机实验条件，发行工具链待选。

| 验证 | 构建进程 | 运行进程 |
| --- | --- | --- |
| 正常任务 | 用 Node `vm.Script` 校验 CJS，写入指定输出目录 | 只读运行宿主移交的产物，正确返回中文 Base64 |
| 合成凭据文件 | 直接读写、符号链接读取均为 EPERM | 同左 |
| 工作目录边界 | 无法读运行阶段的私有文件，无法覆写输入 | 无法读构建阶段的私有文件，无法覆写输入 |
| 网络与子进程 | 回环连接、启动 `/usr/bin/true` 均为 EPERM | 同左 |
| 环境变量 | 未继承合成凭据变量 | 同左 |
| 生命周期 | 正常和异常退出均清理同组后代；超时、取消和输出超限终止进程组 | 同左 |

无隔离对照全部允许，验证探针可以实际触达合成目标。实验策略用 macOS `sandbox-exec` 的默认拒绝配置，分别授权构建和运行。macOS 系统资源、Homebrew 运行库以及文件元数据仍有读取权限。构建样本覆盖本地 CJS 语法校验和产物交接，第三方包管理器、构建插件和依赖未进入本轮。

另一条候选路径把同一 Node 和 Homebrew 动态库放入带 bundle ID 的临时签名 App，启用 App Sandbox，并以 `--jitless` 启动。签名校验及实际启动通过，合成凭据文件和回环网络被拒绝，通过绝对路径复测时，样本输入写入和符号链接读取也被拒绝。候选仍可启动 `/usr/bin/true`，验收脚本因此返回失败。这条候选路径没有通过权限门槛。临时签名不包含 Developer ID 或公证。

## 架构师复审后的隔离方向

复审批准继续原型。优先评估 Apple Virtualization.framework 的最小 Linux 来宾，构建和运行分开，默认不挂载宿主目录或配置网络设备，通过 virtio socket 连接能力代理。依赖 macOS 的扩展需要逐项验证代理行为和可兼容范围。已从宿主 shell 读到 `kern.hv_support=1`，且 `VZVirtualMachine.isSupported=true`。下节记录客户机启动、基础设备边界和单次用时的实测。签名 XPC 和 Node 权限控制可用于分层，但当前证据不足以用它们放行不可信代码。 [架构师复审](codex://threads/01a1cb7d-bfbf-7661-a87f-55264e4ae416) · [Apple Virtualization](https://developer.apple.com/documentation/virtualization) · [Virtio socket](https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice)

## 验收状态

- Swift 全量 91 项测试通过，其中 8 项覆盖原型。分帧测试遍历了有效帧和坏帧组合中的所有单一拆分位置。
- 两组本机隔离实测均有结果。实验内核策略通过表中探针。App Sandbox 单独使用时允许子进程，无法作为当前设计的执行边界。
- CLI 和兼容开发的门槛尚未通过。当前匿名管道是本地实验传输。还需验证可随应用部署的隔离、生产传输、宿主被强制退出后的清理及签名构建下的 Mach 服务和 TCC。进程组验证覆盖普通同组后代，另建会话的后代不在这个边界内。目录枚举、搜索和设置接入后需实测不会启动 JS。社区扩展的运行兼容性仍待验证。
- 两条实验分别提供可重跑的脚本。临时签名实验可能由系统创建测试 bundle 对应的沙箱容器。实验使用的文件和网络目标均为合成数据。

```sh
swift test --scratch-path /private/tmp/keylane-extension-swift-build --disable-sandbox
xcrun swiftc -module-cache-path /private/tmp/keylane-wire-module-cache \
  Sources/KeylaneCore/ExtensionPrototypeSession.swift Tests/ExtensionPrototype/WireBroker.swift \
  -o /private/tmp/keylane-wire-broker
export PYTHONDONTWRITEBYTECODE=1
python3 -O Tests/ExtensionPrototype/verify_supervisor.py
python3 -O Tests/ExtensionPrototype/verify.py /opt/homebrew/bin/node
python3 -O Tests/ExtensionPrototype/verify_wire.py /opt/homebrew/bin/node /private/tmp/keylane-wire-broker
python3 -O Tests/ExtensionPrototype/verify_signed_candidate.py /opt/homebrew/bin/node
```

内核策略测试需从能启动 macOS 沙箱的 shell 运行，Codex 的嵌套沙箱会拒绝 `sandbox_apply`。 [Apple App Sandbox 诊断](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations) · [Node 权限边界](https://nodejs.org/api/permissions.html)

## Linux 来宾原型的实机结果

在 Apple Silicon、macOS 27.3 上，使用临时签名的 Swift 测试程序与 Alpine AArch64 内核 6.12.117。宿主配置无网络设备、共享目录及虚拟磁盘。每个来宾由独立的 initramfs 启动。virtio socket 是样本唯一的宿主应用通信通道，Swift 拒绝 `file.read` 并处理获准的 `echo`。 [Apple Linux 来宾](https://developer.apple.com/documentation/virtualization/creating-and-running-a-linux-virtual-machine) · [Alpine 软件源](https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/)

| 场景 | 实机结果 |
| --- | --- |
| 最小来宾 | 一颗虚拟 CPU、配置 256 MiB。只检测到回环接口，宿主合成标记不存在，握手和回复校验成功。一次启动到确认停止约 0.20 秒 |
| Node 构建来宾 | 一颗虚拟 CPU、配置 384 MiB。Node 22.23.4 以 UID 65534 进行语法校验，通过通道交付产物，宿主与原始样本逐字节核对一致 |
| Node 运行来宾 | 新 VM 和新 initramfs 只接收交接的产物，执行后正确返回中文 Base64 |
| 两个 Node 来宾 | 样本文件不可覆写、无法读取另一阶段的标记和宿主合成文件，外部连接返回 `ENETUNREACH`。本轮一次构建和一次执行的启动到停止均约 1.50 秒，384 MiB 是配置值 |
| 握手超时 | 合成来宾不连接代理，宿主在两秒期限到达时调用 `stop`，确认 VM 状态为 `stopped` 并返回失败 |

上表记录首轮 `vm.Script` 验证。后续验收脚本改用带真实依赖的 TypeScript 样本，并增加以下实测。

- **离线依赖构建。** 构建来宾用 esbuild 0.25.12 将 `dependency.ts` 与固定的 `uuid` 11.1.0 打成单个 CommonJS 产物。Swift 经 virtio socket 收到产物，启动一台只装载该产物的新运行来宾，输出和 Python 独立计算的 UUID v5 一致。运行来宾没有 esbuild 或原始依赖包。npm tarball 的 SHA-512 与上游登记的 integrity 一致，复现脚本按固定 SHA-256 检查后解包。未运行 npm 安装脚本。 [esbuild 构建文档](https://esbuild.github.io/getting-started/) · [uuid 源码](https://github.com/uuidjs/uuid/tree/v11.1.0)
- **来宾进程约束。** esbuild 与 Node 以低权限 UID 启动，并在执行前设置 `no_new_privs` 和 seccomp。AArch64 下仅放行带 `CLONE_THREAD` 的 `clone`，`clone3` 返回 `ENOSYS` 供 libc 回退。构建与运行阶段的 Node 启动子进程均得到 `EPERM`，工作线程均正确返回。此过滤器聚焦进程创建，初次加载程序所用的 `execve` 仍可用。 [Linux seccomp](https://docs.kernel.org/userspace-api/seccomp_filter.html)
- **宿主异常退出。** 来宾进入等待后，外部监督器先观察到唯一新增的 Virtualization VM 服务，再仅向本次临时宿主发送 SIGKILL。宿主自身的超时清理尚未触发，对应 VM 服务在观察期限内退出。此项在单独运行且没有并发启动其他 VM 的环境验证。

发行签名与公证、扩展依赖的通用离线准备与校验、更多对抗样本、实际内存占用和 macOS API 兼容性仍待验收。CLI 和兼容开发继续依照架构评审的放行条件。

复现需要 Apple Silicon、Xcode 工具、Zig、Python 3.12+ 和允许启动虚拟机的 macOS shell。Alpine 内核与 Node 依赖从官方 HTTPS 软件源取得，打包前按固定 SHA-256 校验。本轮锁值由下载物生成，发行制品需独立验证上游签名。脚本只解包固定的内核、模块、Node 和运行库。

```sh
guest=Tests/ExtensionPrototype/LinuxGuest
scratch=$(mktemp -d /private/tmp/keylane-linux.XXXXXX)
mirror=https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64
mkdir "$scratch/apks" "$scratch/npm"
curl -fLsS "$mirror/linux-virt-6.12.117-r0.apk" -o "$scratch/kernel.apk"
while read -r digest package; do
  curl -fLsS "$mirror/$package" -o "$scratch/apks/$package"
done < "$guest/node-packages.sha256"
curl -fLsS https://registry.npmjs.org/@esbuild/linux-arm64/-/linux-arm64-0.25.12.tgz -o "$scratch/npm/esbuild.tgz"
curl -fLsS https://registry.npmjs.org/uuid/-/uuid-11.1.0.tgz -o "$scratch/npm/uuid.tgz"
bash "$guest/verify.sh" "$scratch"
```

### 开发签名与对抗复测

将临时宿主用本机 Apple Development 身份签名，启用 Hardened Runtime，并校验代码签名。测试宿主仅声明 Virtualization entitlement。离线构建与运行、来宾内子进程约束、超时和 SIGKILL 回收均复测通过。

- 在实际 virtio 通道注入坏 JSON、超过 16 KiB 的帧、重复请求 ID 和半帧 EOF。Swift 按预期拒绝，所有对应 VM 都进入 `stopped`。正常路径还注入了旧安装代次的请求，确认它既不触发回复也不推进当前代次的请求 ID。
- 分别替换 esbuild 和 uuid 压缩包内容。制品准备因 SHA-256 不匹配退出，两个场景均未产出可启动的构建镜像。当前准备器覆盖固定样本包，通用依赖解析和包来源签名校验仍待验证。
- `KEYLANE_VM_SIGN_IDENTITY` 可传入已安装的开发签名身份。当前脚本的本机测试签名使用 `--timestamp=none`，默认使用带 Hardened Runtime 的临时签名。发行构建需要 Developer ID、可信时间戳和公证，本机未发现 Developer ID 身份，本轮未执行发行签名或公证。 [Apple Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime) · [Apple 公证准备](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 可信本地扩展的第一批工具

架构师有条件放行可信本地源码的 manifest 解析、命令枚举和 CLI 校验，也允许用固定、已审阅的样本开发 `no-view` 映射。首个可运行里程碑要验证 Node 调用穿过来宾代理后获得完整 Swift 回复，并补齐并发 VM 回收和独立输出限额。第三方安装、公开分发、通用依赖构建和后台执行单独评审。 [架构师复审](codex://threads/01a1cb7d-bfbf-7661-a87f-55264e4ae416)

```sh
swift run keylane-extension validate /path/to/extension
swift run keylane-extension commands /path/to/extension
```

两个命令均只处理所选本地源码的元数据。校验读取受大小限制的 `package.json`，解析 `src/<命令名>.{ts,tsx,js,jsx}`，检查来源目录边界，并拒绝重复、缺失或歧义入口。枚举输出 JSON，包含命令 ID、模式、入口、参数和偏好字段描述。三个模式的枚举结果用于识别命令类型，运行支持仍需逐项验证。CLI 当前通过 SwiftPM 使用，未装入 Keylane DMG。 [Raycast Manifest](https://developers.raycast.com/information/manifest) · [Raycast 源码目录](https://developers.raycast.com/information/file-structure)

在固定提交的 UUID Generator 本地源码上，CLI 校验成功并列出 9 条命令，其中 8 条 `no-view`、1 条 `view`。该验证只读取 manifest 和入口、资源文件的元数据。还用合成样本验证恶意路径、歧义入口、FIFO，以及入口代码与安装脚本均未被触发。 [固定提交的 UUID Generator](https://github.com/raycast/extensions/tree/c33bf4cb4b9ad70c2b93432ee713ffb7486ed331/extensions/uuid-generator)

## 首个可运行的 no-view 样本

固定使用 UUID Generator 提交 `c33bf4cb4b9ad70c2b93432ee713ffb7486ed331` 中的 `src/formatUuid.ts`。构建来宾检查源码 SHA-256，并用固定 esbuild 产出 CommonJS。宿主从构建会话收回制品，校验产物 SHA-256，再为全新的运行来宾准备镜像。样本源码与生成物均留在本地临时目录。 [上游命令源码](https://github.com/raycast/extensions/blob/c33bf4cb4b9ad70c2b93432ee713ffb7486ed331/extensions/uuid-generator/src/formatUuid.ts)

运行来宾的可信启动程序先连接 virtio socket，将专用描述符交给以低权限运行的 Node。Node 中的 `@raycast/api` 适配器实际发起请求并等待 Swift 回复。Swift 用本次 VM 的会话和安装代次验证帧。请求 ID、协议版本及结果或错误随回复返回，Node 在继续执行前检查这些字段。旧代次和未授权调用分别覆盖。来宾 stdout 和 stderr 走串口，与协议通道分开。

| 场景 | 验收 |
| --- | --- |
| 完整往返 | Node 收到相关请求的成功回复与权限错误，再发确认 |
| 固定 UUID 扩展 | 原始 `formatUuid` 命令把 `550e8400e29b41d4a716446655440000` 格式化为 `550e8400-e29b-41d4-a716-446655440000`。Swift 写入并读回独立命名的 AppKit 剪贴板，HUD 消息被测试宿主记录 |
| 权限拒绝 | 选择 paste 时宿主拒绝，原扩展捕获错误并调用 Toast。测试确认没有复制或 HUD 成功事件 |
| 并发清理 | 两台 VM 同时运行。强制杀死第一台的宿主后，仅对应 VM 服务被回收。第二台仍运行，随后经 SIGTERM 取消并停止。另验证了 Node 握手后的取消 |
| 输出上限 | 串口保留至多 32 KiB，协议收、发各至多 64 KiB，单帧限额仍为 16 KiB。串口洪泛、协议洪泛和来宾不读回复均触发限制或期限，相关 VM 均停止 |

复用前面的签名与固定依赖准备步骤，将上游固定源码作为第二个参数即可运行全部验收。

```sh
curl -fLsS https://raw.githubusercontent.com/raycast/extensions/c33bf4cb4b9ad70c2b93432ee713ffb7486ed331/extensions/uuid-generator/src/formatUuid.ts \
  -o "$scratch/formatUuid.ts"
bash "$guest/verify.sh" "$scratch" "$scratch/formatUuid.ts"
```

本次验收使用原型测试宿主和一个命令。真实剪贴板使用独立命名的测试板，HUD 与 Toast 在终端记录，偏好和输入来自固定测试配置。Keylane 应用内入口、用户界面反馈、一般偏好管理和其他命令仍待开发或验收。 [Raycast Clipboard](https://developers.raycast.com/api-reference/clipboard) · [Raycast HUD](https://developers.raycast.com/api-reference/feedback/hud)

## 应用接入范围

此分支交付 CLI、隔离来宾与宿主 helper、Raycast 适配及验证。Store、扩展设置、应用内渲染、安装生命周期与安装版验收将在后续应用接入分支交付。兼容清单记录整个原型的接口状态，涉及应用界面的记录来自独立原型，不能用于证明本分支的应用集成已验收。
