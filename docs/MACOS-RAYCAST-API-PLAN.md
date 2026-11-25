# Keylane macOS Raycast 扩展接入计划

2026-11-25 · EXT-01-a · 待实施

## 目标与基线

交付目标是让现有清单中每个非 OAuth 接口都有可验证的 macOS 接入，最终让商店扩展按实际依赖自动判断能否构建、安装和运行。范围冻结在仓库现有的 `@raycast/api 2.11.1`、`@raycast/utils 2.3.3` 公共声明清单。已验证样本可能使用其他版本，例如 Lorem Ipsum 使用 `@raycast/api 2.12.1`。各版本按实际使用的接口及语义独立验收。冻结基线之后新增的接口另做版本差异表，不能以旧版通过推断新版全量兼容。

- 基线共 1,051 项，其中 **1,007 项纳入计划**，覆盖 `@raycast/api` 980 项与 `@raycast/utils` 27 项。44 项 OAuth 例外包括 `OAuth`、`OAuthService`、`getAccessToken`、`withAccessToken`。其余扩展偏好、敏感字段、用户授予的 macOS 权限、普通 HTTP 请求及 AI 提供方配置仍在计划内。
- 基线上的 696 项 supported、97 项 partial、214 项 missing 是旧兼容状态。逐项表保留这一列，macOS 的源码、运行、商店验收另登记。上轮确认的 37 项也须保留已知语义差异和安装版待验收项。
- 远端 `dev` 核对为 `41dcc4cd`，#222 和 #241 仍开放时制定本计划。当前工作树保留未合入的签名运行器、商店预览和兼容适配。首批整合时刷新前序 PR 和远端状态，保留已有工作，避免把历史证据当作当前产品就绪。
- 沿用受限 JavaScriptCore、进程隔离、宿主按能力代理和撤权机制。代码兼容、扩展命令兼容和外部服务可达性分别验收。扩展自带的 Node 包和原生模块另外建立依赖矩阵。商店中一个扩展可有多个命令，每个命令单独判定。

[基线清单](RAYCAST-API-COVERAGE.csv) · [逐项批次清单](MACOS-RAYCAST-API-BATCHES.csv) · [macOS 运行设计](MACOS-EXTENSION-RUNTIME.md) · [旧运行器行为与证据](RAYCAST-API-COVERAGE.md)

## 批次与验收

表中数字是该批**负责的清单行数**，包括已迁接口的复验、常量成员和旧版别名。一个 PR 按同一接口族交付，代理任务以独立行为及测试为单位，避免为凑条数拆开命名空间。主线是 00 → 01/02 → 03 → 05 → 06 → 07。第 04 批的纯数据与网络工作可在第 02 批后启动，React hooks 等第 03 批；第 08、09、10 批按能力分支并行，最后完成第 11、12 批的剩余关卡。

以下工作可提前并行，完整行为在负责批次收口。02 先完成存储和文件域边界，08 可提前交付文件选择和资源句柄给 04–06 使用。03 负责 React 会话和事件协议，04、05、06、07 复用同一协议。09 的浏览器桥、10 的模型映射和 11 的脚本隔离在 00 完成后即可做可行性验证，避免最后才发现系统或服务缺口。涉及前置批次的条目以最后一个验收条件通过为准，仍由逐项表指定的唯一批次计数。

| 批次 | 条目 | 接入范围 | 通过条件 |
| --- | ---: | --- | --- |
| 00 基线和验收入口 | 0 | 对照最新 dev 与前序 PR，冻结清单。把 JS 适配层、宿主能力、安装收据、命令模式、依赖兼容及验收证据关联到同一命令 ID。将临时固定样本表保留为回归集，逐步切到按命令能力判定。记录导入失败、构建失败、安装不满足与运行失败的具体原因。 | 签名宿主复验 UUID Generator、Silent Mention、Lorem Ipsum 各 3、2、5 条已审阅命令的安装、启动、重启和卸载。分开记录首方模拟、真实公开源码与安装版实机。旧签名收据按原权限继续校验。 |
| 01 纯值和兼容辅助 | 579 | `Icon`、`Color`、`Image.Mask`、快捷键、启动/返回枚举、Toast/Alert 样式、`specialKeys`、纯环境字段、随机 ID、表单校验及头像/进度图、深链字符串生成。环境/图标等引用后续原生能力的行为随相应批次复验。 | 自动比对固定 SDK 导出和别名。JSC 验证值、边界输入、随机长度、中文 URL 编码。图标走原生组件的实机证据随 05–07 验收，深链的实际启动随 07 验收。 |
| 02 偏好、存储和诊断 | 31 | 普通/敏感偏好、旧 `preferences`、命令与扩展设置入口，`Cache`、`LocalStorage` 及别名，assets/support 路径、缓存目录接口和开发诊断。整理两类存储的事务语义，补足已有快照限制、目录语义和双写原子性。 | 验证默认值、必填字段、设置定位、升级与重启、卸载、跨扩展拒绝、并发和故障恢复。权限拒绝或旧票据到达时，数据和界面都保持原状态。开发诊断无用户正文、凭据和隐私字段。 |
| 03 交互运行时与反馈 | 37 | 定义受监督的页面会话及类型化双向事件。接通 React 渲染与更新、`render`、`useId`、`useNavigation`、`useActionPanel`、公共 `Action/ActionPanel`、动态子菜单和 Push，统一 Esc、查询和返回。将阶段性 Toast 更新、确认框、两个反馈动作及 HUD 接入会话。 | 首方 Detail 样板从运行器打开到原生宿主并持续更新，覆盖按钮、快捷键、回调与 Promise 完成顺序。返回、停用、重启、超时能取消旧事件，隐藏和退出能回收。Toast/Alert 回调只能由对应的有效用户交互触发。 |
| 04 数据访问与通用 hooks | 11 | 宿主受控 HTTP(S) 与取消、响应额度、重定向及目的地校验。接入 favicon、`useFetch`、`useStreamJSON`、`executeSQL/useSQL`、`usePromise`、缓存/排序 hooks 和 `withCache`；依赖兼容单测覆盖实际使用的 URL、编码、定时与数据二进制能力。 | 公共 HTTP 和临时文件/SQLite 样板验证查询、分页、取消、缓存、二进制、无网络授权及受控数据库访问。仍处于旧查询代次的响应不能覆盖当前内容。记录包实际用到的 Node 语义。 |
| 05 List 和 Detail | 23 | 原生列表、详情、元数据/标签、筛选、空状态、分页、回调、远程资源和旧别名。扩展文字/Markdown/图片走启动器已验收的列表和详情组件。 | 首方分页搜索样板与固定版本 CHMOD Lookup，覆盖中文 IME、滚动、键盘、跨层返回、异步详情和链接。真实远程资源依赖 04，文件链接依赖 08。 |
| 06 Grid 和 Form | 65 | 网格分组、图标、内距及列导航，原生表单、下拉/标签、日期、文件、密码、Markdown、提交和 `useForm`。旧别名通过同一组件，不分叉 UI。 | 网格和表单真实样板覆盖 Esc、校验、焦点、回车、初始受控值、异步选项、日期/时区及敏感字段擦除。文件选择权限依赖 08，未接通前保留对应差异。对照现有启动器间距和滚动性能。 |
| 07 菜单栏、命令生命周期与深链 | 9 | `MenuBarExtra`、异步菜单、元数据更新、`launchCommand`、`launchType/launchContext`、深链接收与调度。复用 MenuBarRegistry，补齐后台调度、回退命令、唤醒与停用清理。 | 固定版本 Work Time Countdown 样本及跨命令首方样板。测定时、休眠、重开、取消、旧回调、目标已卸载和重复调度，验证空闲能耗。 |
| 08 剪贴板、文件与应用动作 | 40 | 剪贴板读/写/粘贴/清空和完整支持的内容类型，当前选中文本、Finder 选择项，应用目录和前台信息，打开、显示、回收、打开方式、Quick Look 及 Action/旧版别名。补齐受控文件范围和受控 Node 文件适配。 | 用命名剪贴板、临时文件和测试 App 验证内容往返、保密标记、目标切换、失效句柄、选择授权、失败后保留状态及回调。各操作按当前用户动作与收据权限核对。 |
| 09 浏览器和窗口管理 | 11 | Keylane 自有浏览器连接，按标签页和站点授予 `getTabs/getContent`，覆盖文字、HTML、Markdown 与选择器。复用 Keylane 窗口服务，分别实现前台/活动桌面列表、桌面类别、全屏和窗口位置修改。 | 用测试网页和两种浏览器、测试窗口及多显示器/空间验收。重点检查页面导航导致的旧标签页权限、系统权限撤回、前台窗口身份、全屏和空间枚举的准确性。系统缺能力时记录精确差异。 |
| 10 AI 与 Tool | 192 | 对照 SDK 验证 AI 模型常量并独立映射真实可用模型。接 Keylane AI 服务流式输出、取消、模型刷新、工具选择与确认，覆盖 `AI.ask`、`experimental_decide`、`useAI`、旧接口和 tool 入口类型。 | 确定性测试提供方验证 Promise/流事件、取消和工具确认时序，再用已配置模型验证代表命令。公开模型符号与真实可调用模型分开计数。无法等价提供的专用模型保留明确不可用错误；无授权时不得静默选用费率或能力不同的模型。 |
| 11 本机脚本与创建动作 | 9 | 接入创建 Quicklink/Snippet 和 MCP 安装声明，原生编辑/确认后才生效。分别验证 `useExec`、`runAppleScript`、`runPowerShellScript` 能否在固定隔离执行模式下接入。PowerShell 单独验证 macOS 支持和工具链来源。 | 安装 MCP 只登记经验证配置，启动流程另按宿主能力验收。脚本要先证明执行环境能限制访问和后代进程，并能在撤权时彻底回收。只交付经过证明的语义。固定动作、任意脚本文本和任意可执行文件分别验收，后一类不能用前一类的通过替代。 |
| 12 商店准入和完结审计 | 0 | 用锁定版本的真实扩展扩大样本集合，覆盖 no-view、view、menu-bar 和 tool。切换为基于能力的正式兼容判定，检查缺失接口、旧权限和安装升级。按既定 M5 工作清理发行路径与 VM 残留。 | 逐项审计、精确构建签名、CI、安装版重启/升级/撤权/卸载和真实交互。保留用户既有数据和签名要求，性能对照至少覆盖冷启动、首屏、滚动和隐藏静置。 |

[命令生命周期](https://developers.raycast.com/information/lifecycle) · [AI 接口](https://developers.raycast.com/api-reference/ai) · [浏览器接口](https://developers.raycast.com/api-reference/browser-extension) · [窗口管理接口](https://developers.raycast.com/api-reference/window-management) · [useExec 接口](https://developers.raycast.com/utilities/react-hooks/useexec)

## 每批交付与完结口径

1. 每个条目记录 macOS 行为、适用的命令模式、依赖/授权、验证路径及剩余语义差异。区分 `未迁`、`已实现待签名验证`、`部分兼容`、`已验证`、`受阻`。已有导出、所有枚举值、组件渲染和原生动作分别记录对应证据。旧 CSV 的状态不因迁移计划而修改。
2. 每个能力先用首方样板验证正常路径、权限不足和生命周期，再用固定公开扩展源码验证实际入口。商店统计按命令分别记录可构建、可安装、可启动、主要操作通过。仅能列在商店、通过导入检查或支持常量，都不能算扩展可用。
3. 每批 PR 记录前序 PR、最新基线、已验证接口与未完成差异。涉及授权的批次验证拒绝、撤权和旧票据。涉及 UI 的批次对照原生交互和性能。实机包使用本机 Apple Development 签名，记录签名配置、测试环境与结果。
4. 计划收口要求 1,007 项都有对应证据或明确阻塞。**只有 1,007 项全部验证通过，才称为非 OAuth 接口全部接通。** 任意子进程和任意脚本执行、Raycast 专属模型、系统不提供的窗口行为是独立风险。相关小组在早期并行做可行性验证。若现有隔离或系统接口无法实现准确语义，列出具体接口和受影响扩展，保留为阻塞，待产品决定后再实现相应行为。OAuth 的 44 项始终独立列示。

## 第 00 批验收记录

2026-11-25 · 独立工作树验收通过，待合并。核对的远端基线为 `dev 41dcc4cd`，前序 [#222](https://github.com/Acckion/Keylane/pull/222)（`c7b41977`）与 [#241](https://github.com/Acckion/Keylane/pull/241)（`7b1c4639`）当时均开放。保留当前 macOS 预览工作，未直接同步或改写 dev。

- 核对 1,051 条旧清单、1,007 条非 OAuth 分派与 44 条 OAuth 例外。旧清单 SHA-256 为 `707f1346966bdcfd62398a685f52bee38557f657a39f3edbc76a484b7340ab59`。
- 以同一命令审核记录绑定固定源码版本、`@raycast/api` 适配、命令模式与收据授权。构建和收据校验共用这套记录。目前整件收据共享授权，同件命令如果需要不同能力，构建先拒绝，待接入逐命令授权再开放。现有旧收据按其已签名的命令范围和授权核对，测试覆盖旧单命令制品的命令清单恢复。
- 商店区分兼容性检查拒绝、隔离构建失败、安装回执问题、待配置及运行准入失败。当前隔离编译拒绝统一归到构建阶段，尚不按每个缺失符号生成诊断。正式能力准入将在后续批次逐步替换固定样本审核范围。
- Apple Development 签名临时宿主从固定修订构建真实源代码，验证 UUID Generator 的 `formatUuid`、`packTypeID`、`parseTypeID`，Silent Mention 的 `copy-zero-width-space`、`index`，以及 Lorem Ipsum 的 `markdown`、`html`、`paragraphs`、`sentences`、`words`。三款均验证新进程重新打开同一安装、运行和卸载。只捕获输出效果，不写真实剪贴板。使用独立传统钥匙串预览配置。19 项商店观察全通过。 [签名商店报告](evidence/macos-runtime-m2/batch-00-signed-store.json)
- 21 项签名运行器观察、108 项定向 Swift 测试及 81 项发布脚本测试通过。运行器夹具显式声明反馈测试所需能力，避免新存储能力随全量集合被误授予。签名报告中的 `incomplete` 指整个 M2 的产品状态，两个报告内的测试观察均为通过。未替换本机安装版，未声称正式签名配置、正式发行或商店全量兼容。 [签名运行器报告](evidence/macos-runtime-m2/batch-00-signed-runtime.json)

## 第 01 批验收记录

2026-11-25 · 独立工作树的纯值与辅助接口验收通过，待合并。

- Apple Development 签名临时宿主从实际构建所用的两个适配包生成测试命令，并由受限 JavaScriptCore 分别在有权和无权的调用中验证本批全部 579 个导出及成员可访问。固定 `@raycast/api 2.11.1` 公共声明中的 478 个 `Icon` 成员逐个比对名称和值。其他常量、旧别名、只读值、深链编码、头像和进度图结果与旧运行器样本对照。随机 ID 验证默认长度、空值、上限、字符范围和无效长度。
- 增加 `environment.raycastVersion`，从已签名宿主的 `CFBundleShortVersionString` 传递 Keylane 版本，无版本的开发宿主使用 `0.0.0`。该值不能用来推断 Raycast 产品版本或 SDK 能力。`environment.canAccess` 核对当前调用的能力，支持已接入的 Cache、Toast、LocalStorage 和文本复制等相关入口，未授予的能力返回 false。
- 23 项签名运行器检查及 19 项签名商店检查全部通过。后者重验三款真实扩展的十条命令从构建、安装到新进程运行与卸载。108 项相关 Swift 测试、81 项发布脚本测试通过。未安装替换 Mac 上的 Keylane，未增加商店已审核命令。 [签名运行器](evidence/macos-runtime-m2/batch-01-signed-runtime.json) · [签名商店](evidence/macos-runtime-m2/batch-01-signed-store.json)
- 原生图标、头像和进度图渲染留在 05–07 批随界面验收，深链点击后的启动留在第 07 批。这些行为不计入本批的 JavaScript 证据。 [Raycast 环境接口](https://developers.raycast.com/api-reference/environment)

复验命令使用当前 Debug 构建产物和固定官方归档。

```sh
python3 scripts/verify-macos-run-m2.py --products "$PRODUCTS" \
  --batch-01 "$ESBUILD_ARCHIVE" "$RAYCAST_API_2_11_1_ARCHIVE" --report "$NEW_REPORT"
```

## 第 02 批验收记录

2026-11-25 · 存储事务及普通偏好已验证，整批仍有未完成条目，待合并。

- Cache 和 LocalStorage 可在同一次调用原子提交。两个存储独立授权、按安装隔离，各保留 32 KiB 快照上限。新格式可读取旧分离文件；后续写入仅替换相应快照，卸载清理两代文件。签名夹具复验新进程读取、失败调用不提交任何一个存储或设置操作、撤权路径拒绝，以及已授予和未授予的偏好行为。
- `getPreferenceValues` 返回本次普通偏好的独立副本；旧 `preferences` 提供只读元数据、默认配置及当前值。设置入口使用独立的 `preferences.open` 权限，按当前安装、代次和命令路由到原有扩展配置。签名夹具核对路由目标、操作顺序和未授权拒绝；原生界面定位尚未做安装版验收。商店固定审核命令未增加权限。
- `captureException` 和 `captureMemorySnapshot` 获独立诊断权限后，可记录受限的本机诊断。只保留值类别或辅助进程峰值常驻内存，不读取异常正文、动态属性或标签，不向外部发送。JavaScript 堆指标、错误页面内的诊断及开发者中心行为仍未接入，两接口保留部分兼容。
- `environment.assetsPath`、`environment.supportPath`、`Cache#storageDirectory`、`Cache.STORAGE_DIRECTORY_NAME` 仍未接通。绝对路径需要随受控文件能力（第 08 批）一起验证，缓存自定义目录同样保留差异。密码仍缺独立授权和安全存储；文件、目录和应用偏好仍缺选择和授权后的往返验证。
- 27 项 Apple Development 签名运行器检查通过，其中 4 项是本批新增场景。19 项签名商店检查、109 项 Swift 定向测试和 81 项发布脚本测试通过。三款扩展仍通过源码构建、新进程重跑及卸载。未替换本机安装版。 [签名运行器](evidence/macos-runtime-m2/batch-02-signed-runtime.json) · [签名商店](evidence/macos-runtime-m2/batch-02-signed-store.json)

第 02 批签名样本用 `verify-macos-run-m2.py --batch-02 "$ESBUILD_ARCHIVE"` 复跑；可与第 01 批参数同时使用。

## 第 03 批阶段验收记录

2026-11-25 · 受监督的双向页面会话与 HUD 选项切片已验证，整批尚未达到验收条件。

- 首方签名宿主复用现有辅助程序的签名、父进程约束、所有权描述符、退出和超时监督。一次会话只求值一次脚本，后续通过有界帧向同一 JavaScriptCore 上下文发送事件。帧绑定会话和修订号，宿主每次核对 Markdown、动作描述和动作 ID，拒绝失效修订、失效动作和已撤销调用。等待用户事件时，进程监督继续处理超时、取消和子进程退出。
- 首方样本在原进程中显示初始 Detail 数据、异步执行动作、提交新 Detail 数据并返回，验证计数状态仍在。延迟送来的上个页面动作被拦截。样本核对的是进程往返和供原生宿主使用的 Detail 数据，尚未在启动器渲染页面。
- `showHUD` 复用关闭窗口选项校验，对显式的立即或暂缓返回选项使用已有关闭窗口授权。签名样本证实有权时按顺序提交效果，无关闭窗口权限时拒绝整次调用。默认提示路径仍保留。
- 尚待接入：React 渲染和更新、签名商店 view 命令的准入、本机页面宿主和 Escape、动作菜单与快捷键、`render`、`useId`、`useNavigation`、`useActionPanel`、交互确认和 Toast 按钮。阶段性 Toast 与 Promise 等待用户交互也需随完整会话验收。本批不改商店可运行命令或兼容统计。
- 32 项签名运行器、19 项签名商店、109 项相关 Swift 和 81 项发布脚本检查通过；其中 5 项为本批的会话与 HUD 场景。三款既有扩展、10 条命令的构建、安装、新进程运行和卸载回归通过。未替换本机安装版。 [签名运行器](evidence/macos-runtime-m2/batch-03-signed-runtime.json) · [签名商店](evidence/macos-runtime-m2/batch-03-signed-store.json)

第 03 批样本使用 `verify-macos-run-m2.py --batch-03 "$ESBUILD_ARCHIVE"` 复跑。

### 第 02 批补验：资源与支持目录

2026-11-25 · 接通 `environment.assetsPath` 和 `environment.supportPath` 的受控文件子集。两个目录分别要求显式的 `files.assets.read` 与 `files.support.write` 权限，现有商店命令未增加权限。

- `/assets` 只投影签名制品的资源文件，最多 128 个、合计 512 KiB。`/support` 按安装持久保存，最多 32 个、合计 32 KiB，和 Cache、LocalStorage 共用原子提交。来宾目录由受控文件接口解析，与宿主文件路径无直接映射。
- 受审核的构建可解析 `fs`、`node:fs`、`fs/promises` 和 `node:fs/promises` 的读写文件子集。支持 UTF-8 文本与字节数据，二进制读取返回 `Uint8Array`。目录枚举、文件删除、Node Buffer 和文件描述符未纳入此次适配。 [Raycast 环境接口](https://developers.raycast.com/api-reference/environment) · [Node 文件接口](https://nodejs.org/api/fs.html)
- 35 项签名运行器检查通过，覆盖资源读取、支持文件写入、新进程重读、无授权和越界拒绝。新增 Swift 回归核对安装隔离、卸载清理和非法支持文件不会让 LocalStorage 部分提交。110 项 Swift 定向测试和 81 项发布脚本检查通过。 [签名运行器报告](evidence/macos-runtime-m2/batch-02-scoped-files-runtime.json)
- 签名构建器成功编译引用受控文件模块的首方样本。20 项签名商店检查通过，包含既有三款扩展的 10 条命令构建、安装、重开运行和卸载。 [签名商店报告](evidence/macos-runtime-m2/batch-02-scoped-files-store.json)
- 第 02 批仍未完结。Cache 目录接口、敏感偏好及文件／目录／应用选择型偏好、完整诊断和设置定位实机验收仍待完成。未替换 Mac 安装版。

### 第 02 批补验：Cache 目录、偏好与诊断

2026-11-25 · 工作树实现已接入，安装版设置交互待验收。

- Cache 提供 `STORAGE_DIRECTORY_NAME`、`storageDirectory` 和安装内的自定义父目录。默认目录为 `/support/cache`，自定义父目录限定在 `/support`。每个目录和命名空间独立，旧默认命名空间快照可读，`entries.json` 由受控文件接口只读投影，不映射宿主路径。每安装的 32 KiB 总预算继续适用。
- 文件、目录、应用选择复用原生选择面板。授权命令分别收到选中的路径和应用描述对象。选择型授权负责传值，文件操作仍按各自能力验证。
- 密码只在受保护配置和带有独立 `preferences.secrets.read` 授权的安装中启用。密钥由受保护配置派生，绑定安装身份的 AES-GCM 密文与偏好一起提交。设置界面只能查询是否已填写。仅获授权的命令能从当前运行读取密码，新修订安装需要重新填写。传统钥匙串预览保留普通功能。
- 诊断已接到扩展详情的「本机运行诊断」，每个安装保留最近 16 条，当前运行和代次有效时才发布。仅展示异常类别、辅助进程常驻内存和峰值。JavaScriptCore 公共接口不提供等价 JS 堆统计，Raycast Developer Hub 上传未接入，诊断仍按部分兼容追踪。 [Apple JavaScriptCore](https://developer.apple.com/documentation/javascriptcore) · [Raycast 诊断接口](https://developers.raycast.com/api-reference/utilities)
- 115 项 Swift 定向测试、81 项发布脚本测试和 36 项签名运行器检查通过。签名样本验证了缓存目录隔离和只读索引、密码及选择值的授权与拒绝、常驻内存及异常数据交付。未替换本机安装版。 [签名运行器](evidence/macos-runtime-m2/batch-02-preferences-cache-diagnostics-runtime.json)
- 15 项受保护配置签名检查通过，包括用已签名测试宿主重开凭据密钥、拒绝跨安装解密以及受控文件模块的签名构建。20 项预览商店检查通过，覆盖既有三款扩展 10 条命令。当前商店样本权限保持原样，新增权限的验证来自首方夹具。 [受保护配置](evidence/macos-runtime-m2/batch-02-preferences-cache-diagnostics-vault.json) · [预览商店](evidence/macos-runtime-m2/batch-02-preferences-cache-diagnostics-store.json)

### 第 03 批补验：React 挂载与交互反馈

2026-11-25 · 首方签名夹具验证真实 React 19.0.0、react-reconciler 0.31.0、scheduler 0.25.0。组件在同一 JavaScriptCore 进程内挂载，执行两次子菜单动作后产生三次不同的页面快照，React 的状态和 useId 保持稳定。测试依赖按摘要锁定，只进入测试制品。

页面协议支持最多四层的静态子菜单、确认与取消结果、Toast 主副动作。宿主按当前帧校验动作 ID 和类型。存在模态确认时只能确认或取消，菜单分组不能当作叶动作，普通菜单 ID 不能当作 Toast 按钮，失效帧和撤权沿用已有拒绝路径。

115 项相关 Swift 测试及 32 项 Apple Development 签名运行器检查通过，其中新增 6 项 React 与反馈场景。当前验证覆盖渲染夹具和宿主协议。正式运行器中的 Raycast React 适配器、商店视图命令准入，以及 Launcher 的原生呈现、快捷键、动态菜单、确认框、Toast 按钮和交互 Promise 尚未接入，整批仍未完成。 [签名报告](evidence/macos-runtime-m2/batch-03-react-feedback.json) · [React 渲染器接口](https://github.com/react/react/tree/main/packages/react-reconciler)

### 第 03 批续验：生产 React 路径与启动器

2026-11-25 · 代码已接到签名构建、运行准入和 Launcher，待合并。运行器已经过首方签名样板验证，安装版交互与公开 view 扩展尚未验收。

- 签名构建仅为明确审核的 view 命令引入按完整性锁定的 React 19、react-reconciler 和 scheduler。实际构建使用统一的入口包装与 API 适配器，原始入口路径、收据、授权与撤权机制继续复用。签名样板也验证了构建产物保留 MIT 通知。
- Launcher 使用公共页面、Markdown、动作菜单、返回与快捷键路径。支持同一会话内的 Detail 更新、`render`、`useId`、`useNavigation`、`useActionPanel.update`、Action.Push、动作分组和动态子菜单。无效修订、未授权的宿主动作、没有 UI 宿主的视图调用均拒绝。离开或隐藏页面取消会话，旧会话不能发布；签名样板核对撤权停止进程。本批未增加任何默认商店授予。
- 支持确认和取消 Promise、危险按钮样式、Toast 样式、阶段更新和两个原生按钮。HUD、关闭窗口、清搜索和回根页继续各自核对原有授权。Modal 等待不会占用事件队列。首方签名样板验证了确认、取消、父页面状态、菜单查询、撤权和授权不足。
- 本阶段只支持受监督的 Detail。确认框记住选择、自定义图标、会话外 Toast 按钮和部分外观语义未做到 Raycast 等价。列表、网格、表单及其他页面组件由后续批次负责。签名样板不等于已有公开商店 view 命令通过实机测试。未覆盖 Mac 安装版。
- 112 项 Swift 定向测试、81 项发布脚本检查、40 项签名运行器检查及 21 项签名构建和商店检查通过。三款原有公开扩展十条无界面命令保持可构建、安装、运行和卸载。
- [37 项独立证据](evidence/macos-runtime-m2/batch-03-interface-evidence.csv) · [签名运行器复验](evidence/macos-runtime-m2/batch-03-launcher-signed-runtime.json) · [签名构建与真实扩展回归](evidence/macos-runtime-m2/batch-03-launcher-signed-builder.json) · [Raycast 动作菜单](https://developers.raycast.com/api-reference/user-interface/action-panel) · [Raycast 导航](https://developers.raycast.com/api-reference/user-interface/navigation) · [Raycast 确认](https://developers.raycast.com/api-reference/feedback/alert) · [Raycast Toast](https://developers.raycast.com/api-reference/feedback/toast)
