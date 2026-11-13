# Raycast API 兼容清单

第三方扩展从 `@raycast/api` 导入组件、函数和常量，Keylane 在隔离来宾中提供同名模块，由宿主验证并执行需要本机能力的请求。`@raycast/utils` 是在宿主 API 上提供的工具库，兼容范围也包含它的公开非 OAuth 接口。基线为 2026-11-12 核对的 [@raycast/api 2.11.1](https://www.npmjs.com/package/@raycast/api/v/2.11.1)、[@raycast/utils 2.3.3](https://www.npmjs.com/package/@raycast/utils/v/2.3.3) 和 [官方开发者文档](https://developers.raycast.com/llms.txt)。

[逐项清单](RAYCAST-API-COVERAGE.csv) 从上述版本的公开 TypeScript 声明枚举运行时导出、组件子项、公开类成员和枚举值，并补充 Tool 的确认入口。组件属性、回调与函数重载按各接口的验收记录检查。枚举和常量的状态描述导出的 JavaScript 值。CSV 中 `#` 表示实例成员。`supported` 表示当前兼容的行为，`partial` 表示样本限定或能力有缺口，`missing` 表示尚未提供，`excluded_oauth` 表示 OAuth 例外。

`Form.Checkbox`、`Form.TextField`、`Form.DatePicker`、`Form.TagPicker` 和各自的旧版导出使用相同的表单协议。字段支持受控值、初值、变更与焦点回调、提交后的值恢复，以及通过 ref 聚焦和重置。日期回调将传输值转换为 `Date` 或 `null`，保留全天分类；标签回调收到经当前选项验证的数组。Form 容器仍使用有上限的快照和事件回放，密码表单不会持久化字段。Markdown 文本区域的完整快捷键与语法高亮、远程选项图标以及敏感字段的额外交互仍按各自项目跟踪。

## 已接入与待补行为

| 范围 | 当前实现 | 尚需接入或验证 |
| --- | --- | --- |
| 环境与启动 | 三种模式传入扩展名、作者、入口名、模式、开发状态、外观、字号、启动类型。菜单栏定时执行传入 `LaunchType.Background`。兼容旧字段 `theme`、`commandName`、`commandMode` | 制品的通用资源打包、跨运行支持目录、其他接口的授权探测、`raycastVersion` 与宿主启动上下文调度。目前入口类型仅有 `command`，`tool` 要随 Tool 执行接入。字号将 Keylane 的「大」映射为 `large`，其余映射为 `medium` |
| 偏好与持久化 | `getPreferenceValues` 与旧版 `preferences` 字段记录、扩展隔离的受限 `Cache`、`LocalStorage` 的已审阅签名命令持久化及五个旧版别名、菜单栏样本打开命令设置，显式操作中的 `openExtensionPreferences` 打开当前扩展设置 | 跨扩展通用作用域、所有值类型、必填字段与敏感值、自定义缓存目录与更大的容量、扩展设置的后台调用及通用 `openCommandPreferences` |
| 剪贴板与反馈 | 已审阅命令的纯文本 `Clipboard.copy/paste` 与 `copyTextToClipboard/pasteText` 别名、`Action.Paste` 及旧 `PasteAction` 的文本操作、已审阅视图选中动作的数字、HTML、纯文本和文件引用写入、保密复制标记、复制完成回调，受限的 HUD、Toast 和确认框，提供官方 `Toast.Style` 枚举与旧 `ToastStyle` 别名 | 剪贴板读取的富文本、文件与历史条目、`Action.Paste.onPaste`、历史偏移、选项及无界面命令的剪贴板清空、Toast 交互动作与跨来宾实时生命周期、HUD 选项、通用确认框 |
| 视图、动作与资源 | `List`、`List.Section`、`List.Item`、行详情的链接、标签组与标签、List 默认标题和关键词过滤与 `List.EmptyView`、List/Grid 下拉分组、独立搜索、筛选排序、加载反馈及选择恢复、`Grid`（分组、网格布局、标题和关键词过滤、空状态、操作、色块与内嵌 PNG/JPEG）、独立 `Detail`（原生块级 Markdown、标题、静态加载提示、文字元数据、HTTP(S) 元数据链接和操作栏）、`Form` 的单行和多行文本、复选框、分组下拉、日期时间、多选标签、安全密码输入、文件路径选择、HTTP(S) 附件链接、说明、分隔线及 `Action.SubmitForm`、基本 `Action`、`Action.CopyToClipboard`、`Action.PickDate`、快捷链接与文字片段草稿、`ActionPanel` 与 `ActionPanel.Section` 标题、动态嵌套 `Submenu` 和视图动作快捷键、稳定的来宾 `useId`、旧版 `specialKeys`、全部公开 `Icon` 枚举值、九个标准 `Color` 枚举值、`Image.Mask` 与旧别名、十七组 `Keyboard.Shortcut.Common` | Grid 分页、选中回调与远程资源图片，其他 Form 字段的回调、持久化及文件读取授权，文本区域 Markdown 完整快捷键和语法高亮，独立 Detail 的表格、图片、Markdown 正文链接跳转、LaTeX、异步加载与远程资源，List/Grid 下拉选项的外部图标、子菜单的外部图标与持续挂载、日期回调后的完整 React 生命周期、其他创建动作及更多 Action、React 状态和回调、资源与图片渲染、更多图标及其他动态颜色 |
| 导航与命令调用 | 已登记命令入口，显式操作中的 `popToRoot`、`closeMainWindow`、`clearSearchBar` 和 `PopToRootType`，通过 `Action.Push`、`PushAction` 与 `useNavigation` 在同一命令内切换页面 | 完整的 React 挂载、`useActionPanel` 在渲染周期外更新、`launchCommand`、`render`、导航完成回执及自动调用、launch context、回退命令和 deeplink |
| 菜单栏与定时执行 | 已审阅的 Work Time Countdown 使用 `MenuBarExtra` 和 `updateCommandMetadata` 的字幕。菜单树支持 `Item`、`Section`、`Submenu`、`Separator`、字幕、提示、macOS 快捷键及左键回调 | 菜单打开时的长生命周期、异步加载、Option alternate、右键回调、任意图标、通用宿主动作与元数据 |
| 宿主工具 | 用户显式操作可通过 `Action.Open` 及回调中的 `open` 打开 HTTP(S) 网页、普通文档或文件夹，并可指定已登记应用。`Action.OpenInBrowser` 与列表元数据链接可打开 HTTP(S) 网页。签名应用的已审阅命令可查询安装应用、文件类型关联和前台应用 | 其他 URL 协议、通用无界面授权和动作外部图标，`showInFinder`、`trash`、逐文件的应用关联覆盖、Finder 选择项、选中文本、`BrowserExtension`、`WindowManagement`、诊断与性能快照 |
| AI 与 Tool | — | `AI`、旧 AI 接口、Tool 清单入口、执行和确认回调。服务与授权条件需随对应接口验证 |
| Utilities | 支持 `FormValidation.Required` 、来宾文件上的只读 `executeSQL` 查询、`getAvatarIcon`、`getProgressIcon`、`showFailureToast`、`useForm`、`usePromise` 及授权范围内的 `useLocalStorage`，另支持 `useCachedState`、`withCache`、`useCachedPromise` 与 `useFrecencySorting` 的有限缓存、`DeeplinkType`、内联 `useFetch`、来宾 JSON 的 `useStreamJSON` 与只读 `useSQL`。List 和 Grid 原生绘制来宾生成的头像和进度环 | 宿主数据库和文件访问、HTTP(S) 数据请求、缓存 hooks 的持续挂载和防抖、实时表单事件、Promise 分页、排序、跨扩展通用存储、脚本、其他图片工具、AI、Toast 实例及按钮和 deeplink。逐项见 CSV |

签名隔离虚拟机用合成命令验证三种模式在模块加载时可读取环境值，并核对命令启动类型与 Toast 常量。用固定版本的真实样本回归 UUID 格式化、UUID 生成、CHMOD Lookup 和 Work Time Countdown。Swift 测试覆盖宿主编译与既有行为。第二轮隔离验证覆盖嵌套菜单的序列化和回调、Utilities 导入、SQLite 查询和来宾边界。独立 Detail 使用合成扩展验证文档与元数据往返、复制请求和回调，并用固定版本 CHMOD Lookup 回归原有的列表详情。Grid 使用合成扩展验证分组、图片传输、中文关键词过滤、空状态和操作回放。Form、List 与静态子菜单使用签名合成扩展验证类型化提交、错误拒绝、筛选与嵌套操作，回归固定版本 CHMOD Lookup 与 UUID History。搜索和下拉回调在隔离进程中重建当前视图状态，期间不会执行 LocalStorage 写入。日期字段以 UTC 保留纯日期的日历日，日期时间字段保持原时间点。

[扩展兼容与验收](RAYCAST-COMPATIBILITY.md)

网址打开在宿主再次校验，视图渲染和被动搜索或下拉回调无法发起。头像与进度图通过受限数据传递原生绘制参数。List 和 Grid 支持这些参数，任意 SVG 及其他界面中的 SVG 资源仍需接入。

`Action.Paste` 通过现有自动粘贴路径向发起操作时的应用提交纯文本。扩展结果返回时会重新确认目标身份，应用变更、退出或缺少跨应用粘贴权限时保留复制结果。独立 Detail 的链接复用列表详情的用户点击校验。

密码只随显式提交通过有上限的输入传入来宾，宿主清空密码字段。敏感调用的串口日志不会输出，回复只保留成功或失败类型。文件选择只返回用户选中的绝对路径。导航由宿主在收到显式操作结果后执行，每次调用只应用一个宿主操作。

扩展可发起快捷链接和文字片段的编辑草稿，由用户在原生编辑器保存。日期动作仅在用户确认或明确清除时回放回调。回执绑定到所选动作和日期范围，全天日期沿用来宾 UTC 日历。没有其他界面操作时，回调的状态变化会立即渲染到当前视图。数据 hooks 只访问内联数据或来宾文件，保留虚拟机网络和宿主文件边界。

已审阅视图命令使用独立的 4 KiB 缓存快照，按扩展目录原子保存。来宾仅能读写当前扩展的快照；敏感提交不携带快照。扩展内导航最多四层，返回时恢复父页面的搜索词与筛选项。隔离回放会重建页面和动作，禁止回放中的宿主操作和持久化写入，包括派生的异步回调。

旧版 `ListItem`、`ListSection`、`FormCheckbox`、`FormDropdown`、`FormDropdownItem`、`CopyToClipboardAction`、`OpenAction` 和 `OpenInBrowserAction` 直接复用对应的现有组件及能力边界。已审阅来宾的 `randomId` 默认生成 21 位 URL 安全随机字符串，允许指定 0 到 4096 位。旧版 Raycast 运行时的具体格式仍待核对。

旧版 `FormSeparator`、`FormTextArea`、`FormTextField` 和 `ActionPanelItem` 复用已审阅视图的表单与动作组件。`Alert.ActionStyle` 和 `AlertActionStyle` 在视图与无界面来宾中提供相同的样式值，沿用现有确认授权。

`useCachedPromise` 从扩展的缓存快照读取 JSON 结果并在正常渲染时刷新。路由回放只读缓存，分页和写入防抖仍待接入。`useFrecencySorting` 使用七天半衰期和每命名空间最多 24 项的访问记录，在后续视图快照应用排序。两个 hooks 共用扩展的 4 KiB 缓存预算。`DeeplinkType` 提供两个枚举值，三个深链构造函数生成 Raycast URL，Keylane 的深链打开与调度仍待接入。来宾沙箱禁止创建子进程，`useExec` 仍待接入。

`getApplications`、`getDefaultApplication` 与 `getFrontmostApplication` 仅在签名 Keylane 启动已封装的审阅制品时获得授权，敏感提交禁用。宿主在标准目录枚举应用，文件查询仅接收扩展名或目录提示，并限制返回大小与查询次数。签名测试使用合成应用记录验证正常回包，并核对独立 helper、伪造路径与敏感提交的拒绝路径。

旧版 `useActionPanel().update` 在已审阅视图渲染和渲染副作用期间覆盖操作面板，选中动作沿用现有验证。`captureException` 只记录 JavaScript 值类型，`captureMemorySnapshot` 在开发模式记录堆大小。两者的有界记录随来宾退出销毁，尚无开发者中心上传、宿主诊断展示或内存不足后的采样流程。

已审阅视图的显式操作支持 `Action.ShowInFinder`、`Action.Trash`、`Action.OpenWith` 及其旧版别名。宿主重新验证路径。Finder 接受选中请求后触发 `onShow`。打开方式复用原生操作窗口，支持本地路径和经验证的 HTTP(S) 网址，所选应用打开目标成功后触发 `onOpen`。废纸篓操作接受最多八个路径，展示完整路径并征得确认，再核对文件身份，全部成功后触发 `onTrash`。回调收到原始参数，完成回执不能用于新的文件或剪贴板操作。独立函数 `showInFinder` 和 `trash` 的 Promise 目前在提交请求时返回。

`Clipboard.clear` 与 `clearClipboard` 在显式选中的视图回调中提交清空请求。宿主确认后清空相应剪贴板；等待过程中若剪贴板已变化，则保留新内容。无界面命令目前没有这些宿主操作。

`Clipboard.read` 与 `Clipboard.readText` 在签名已审阅视图的显式回调中读取当前纯文本。宿主只在收到读取请求时访问剪贴板，并校验剪贴板版本、敏感状态及应用签名。独立命名剪贴板的中文读取和拒绝路径已在签名虚拟机验证。`environment.canAccess` 按已登记的接口身份与授权判断，覆盖剪贴板读取和窗口读取。

`ActionPanel.Item` 复用 `Action` 的现有成员。`Action.ToggleQuickLook` 对当前 List/Grid 项的本地普通文件使用原生预览面板，支持标题、图标、快捷键、`quickLook.name` 与当前用户的 `~/` 路径，再次触发可关闭。签名虚拟机测试覆盖了文件动作、回调原始参数与无效回执，原生测试使用临时文件和测试 App 验证系统操作。

`environment.assetsPath` 指向来宾制品中的只读 `/assets`，`environment.supportPath` 指向来宾可写且随 VM 销毁的 `/support`。旧版 `environment.launchContext` 接收宿主输入的有界 JSON 对象，宿主命令调度仍待接入。

旧版 `Form.DropdownItem`、`Form.DropdownSection`、`Form.TagPickerItem` 复用对应的现有表单组件。`Icon.ArrowClockwise` 和 `Icon.ArrowCounterClockwise` 保留 Raycast 枚举值，通过原生 SF Symbols 渲染。`Color.Brown` 使用 Keylane 提供的浅色和深色值，应用于列表图标、网格图标和色块。

`new Toast(options)` 创建实例，`show()` 与 `hide()` 在一次来宾运行内按顺序更新待显示反馈。`showToast` 返回同类型实例。已审阅视图在回调结束后显示仍有效的最终反馈，动画样式使用中性反馈。无界面验证宿主记录显示事件；实际界面的实时更新和按钮回调仍待接入。

`Toast.style`、`Toast.title`、`Toast.message` 支持读写。已审阅视图在一次显式回调内按调用顺序应用修改，并只提交当前仍有效的反馈。无界面来宾支持实例字段读写，原有反馈桥仍记录显式显示事件。

`Icon.Plus`、`Icon.Check`、`Icon.MagnifyingGlass` 使用 Raycast 的枚举值并通过 macOS SF Symbols 渲染。

`WindowManagement.getActiveWindow` 与 `getWindowsOnActiveDesktop` 可从已审阅签名视图的显式回调读取有界的可见窗口元数据。`environment.canAccess` 检查当前授权。前台窗口取启动器唤起前应用的最靠前可见窗口，桌面标识代表当前可见桌面，窗口标题不传入来宾。窗口移动和精确 Spaces 枚举仍待接入。

`Icon.Clipboard`、`Icon.Clock`、`Icon.Document`、`Icon.Folder`、`Icon.Key`、`Icon.Link`、`Icon.Pencil`、`Icon.Tag`、`Icon.Trash` 已使用公开 SDK 声明中的字符串值。视图和菜单栏共用原生 SF Symbols 映射，继续识别早期审阅制品使用的旧字符串。

`Icon.Warning` 使用 SDK 声明的 `warning-16`，映射到原生警告符号。`Action.Style` 与旧版 `ActionPanel.Item.Style` 共用 SDK 的枚举值，`Destructive` 传入 Keylane 原生操作菜单的破坏性样式。三个 `isFullDay` 入口都识别日期选择器返回的全天日期，区分恰好在午夜的日期时间和空值。仅包含标签及分隔线的行详情也保留分隔线。

`ActionPanel.Section` 与 `ActionPanelSection` 将标题传入操作菜单，过滤后仍保留对应的标题。
`List.Section` 与 `ListSection` 支持标题和副标题，并区分同名相邻分组。
`Form.Dropdown.Section` 及两个旧别名的验收覆盖可选标题、空分组、散列项和带分组的值提交。
`Cache.has()` 与 `Cache.isEmpty` 在已配置的命名空间中检查存在性，不写入快照或调整 LRU 顺序。Cache 类的授权和容量边界仍适用。

已审阅视图的缓存快照按 LRU 顺序持久化，旧字典格式可继续读取。`Cache.get` 更新命名空间内访问顺序，回放时只读。`Cache.remove`、`Cache.clear` 和 `Cache.subscribe` 支持删除结果、清空通知开关和独立取消订阅。`Cache` 类及 `set` 仍受 4 KiB 快照预算和已审阅视图作用域限制。

已审阅的视图、菜单栏和无界面命令可以通过宿主代理访问独立的 Keychain 存储。字符串键按 JavaScript UTF‑16 编码，布尔值、数字和字符串可跨调用保存。敏感提交和未获授权的独立 helper 无法访问。UUID 历史继续使用已有的专项存储。`LocalStorage`、`setItem` 与 `setLocalStorageItem` 仍标为部分兼容，当前通用存储每扩展上限为 4 KiB。

`List.Dropdown.Section` 与 `Grid.Dropdown.Section` 在原生下拉面板保留组标题和组间分隔线，无标题组也能区分。筛选后保留仍有匹配项的分组。

`Grid.Section` 支持分组标题、副标题、列数、宽高比、填充模式和内距。未指定的布局沿用父网格设置，方向键在不同列数的分组之间按可用列移动。签名隔离 VM 验证布局覆盖值的协议往返，Swift 测试覆盖跨组导航。

`List.Dropdown` 和 `Grid.Dropdown` 可独立搜索，在声明回调时默认使用扩展筛选，也可显式启用原生筛选及保留组顺序。原生控件显示加载状态，可按声明节流输入。宿主按扩展、命令及下拉 ID 保存最多四条有效选项，恢复时由当前候选项验证并保留受控值优先。签名隔离 VM 覆盖搜索、动态选项动作回放及新调用的选项恢复。外部选项图标仍在两个 `Dropdown.Item` 条目中跟踪。

`ActionPanel.title` 随列表或网格的当前项目、空状态、详情及表单传入原生操作菜单，并跟随渲染期间的面板覆盖。动作描述包含经校验的 macOS 按键和 `autoFocus`，启动器将前两个动作绑定到对应页面的默认按键组合。无修饰键的自定义快捷键在操作菜单打开时生效，原有的回车、退出和启动器快捷键保留。签名隔离 VM 覆盖四种页面的协议往返和普通动作回调。外部图标及其他动作专属行为仍按各接口记录。

独立详情与列表行详情共用元数据和标签组解析。两者保留子项顺序、组标题、空组、内置图标及浅色和深色标签颜色，旧独立详情的纯文本标签仍可读取。四个容器条目各自覆盖 `children`，标签组也覆盖 `title`。标签项的外部图标和点击回调继续在对应子项中跟踪。

操作子菜单支持 `onOpen`、独立搜索、原生分组排序、输入节流和加载提示。来宾按当前分组路径重建子菜单，只有明确选择的叶动作才能执行宿主操作。旧版 `ActionPanelSubmenu` 共用实现。子菜单在隔离进程中重放生命周期，尚未提供长期挂载的异步状态与外部图标，因此这两个条目仍为部分兼容。

已审阅视图通过 `Action.CopyToClipboard` 和 `Action.Paste` 传送文本、数字、HTML 与本地文件引用。显式选中的普通回调也可请求 `Clipboard.copy` 和 `Clipboard.paste`，支持保密复制和保留启动器。宿主在写入前验证类型及路径，保密内容使用剪贴板历史已识别的排除标记。复制动作接受旧版 `transient`，显式设置 `concealed` 时优先。宿主成功写入后才以回执重建 `onCopy`，传入扩展声明的原始内容和类型。合成扩展通过签名 VM 验证协议，AppKit 测试使用独立命名剪贴板。通用无界面授权、远程图标和 `onPaste` 仍待接入。

视图、菜单栏与无界面适配器共同导出 SDK 2.11.1 的 478 个 `Icon` 成员，包含旧名和共用同一标识符的别名。原生界面将标识符映射到 macOS 系统符号。51 至 99 的数字图标使用通用数字符号，Raycast 品牌标识使用通用闪电符号。逐项状态对应 JavaScript 枚举值。九个标准 `Color` 枚举值也已核对，旧版 `Color.Brown` 及额外颜色格式仍按各自能力跟踪。

`Action.Open` 与 `Action.OpenInBrowser` 的 `onOpen` 在 macOS 返回成功后按操作和内容回执重建，参数保留扩展提供的原始目标。文件和应用仍由宿主校验。普通文件和目录可打开，可执行文件、脚本和应用包不在文件目标范围内。测试核对已登记应用解析、文件校验、隔离 VM 的请求和回执往返。其他协议、外部动作图标和通用无界面 `open` 仍在相应条目跟踪。

表单变更、焦点和失焦回调按交互顺序在独立来宾中重建，保留最近 16 个事件，同一字段在一次防抖间隔内连续输入的文本合并为最终值。已提交的 `storeValue` 值按表单字段结构保存，受控值优先。密码字段不进入实时回放和持久化。持续 React 挂载及逐次击键跟踪仍待接入。

已审阅运行制品可用 `prepare.py --assets-manifest` 将有 SHA-256 记录的资源打包到来宾 `/assets`。扩展通过 `environment.assetsPath` 获取该只读目录。共享图标渲染支持小型 PNG/JPEG、内置符号、单个 emoji、深浅色变体、回退图标、裁切和色调，已接入列表、网格、下拉选项、操作菜单、表单选项和元数据标签。位图受原有单次输出配额约束。远程图片、SVG 与宿主文件图标仍在对应组件中跟踪。

`Action.SubmitForm` 及旧版别名识别同步或异步的 `false`，展示表单更新后的校验信息并允许用户编辑后重试。失败不保存 `storeValue`，减少动态效果时关闭失败提示。敏感表单的签名宿主仅传递成功、失败或拒绝状态。日期与提交回调产生的视图更新属于当前快照，后续请求仍使用隔离来宾重建。

`Action.Push` 及旧版别名在宿主发出的显式进入、返回事件上执行 `onPush` 与 `onPop`。路由重建和搜索刷新不触发生命周期回调。回调可以使用已授权的扩展存储，返回时可更新父视图快照。回调结束后的异步写入和新的宿主操作受现有隔离限制。启动器关闭会结束整个视图会话。

`Action.Open`、`Action.OpenInBrowser` 与旧版别名提供 SDK 默认图标，并在宿主打开成功后以原始目标调用 `onOpen`。回执区分不同动作和指向同一 URL 的不同原始输入。Open 支持绝对路径、本地文件 URL、当前用户的 `~/` 路径和 HTTP(S)，应用选择器可使用已登记应用的名称、Bundle ID 或路径。OpenInBrowser 显式使用 macOS 默认浏览器。可执行目标与其他 URL 协议仍受宿主校验限制。

`Action.CreateSnippet` 和旧入口把文本、名称及缩写预填到原生编辑器。用户确认保存后才写入资料库，取消可回到扩展页面。签名虚拟机核对了草稿字段和打开回执，原生测试核对了 Launch Services 应用解析、可执行文件拒绝及独立 SQLite 草稿保存。

独立 Detail 与 List 行详情共用元数据渲染。Label 支持图标和深浅色文本，TagList.Item 支持显式点击回调。标签回执绑定当前列表行及标签内容，过期或跨行回执会被拒绝。回调可刷新当前快照。List 行详情显示加载指示并复用独立 Detail 的 Markdown 渲染，Markdown 仍受现有格式和资源范围限制。Form 标签选项在菜单和已选项中使用相同的图标。

`Form.Dropdown`、`Form.Dropdown.Item` 及旧版别名复用原生搜索选择器。支持分组与关键词、筛选顺序、搜索回调、节流和加载提示，以及表单的受控值、事件、重置和提交后保存。搜索隐藏当前值时保留本次表单已验证的选项。搜索回调沿用表单回放的隔离约束。`Form.LinkAccessory` 使用原生导航链接，激活时仍由宿主复核 HTTP(S) 目标。签名虚拟机与 macOS 测试窗口分别验证了协议往返、关键词回车选择和链接点击。


列表与网格空状态遵循搜索与加载状态。当加载且搜索为空时隐藏空状态，已有匹配结果时也不显示。网格空状态的操作面板优先于根网格操作，嵌套菜单与选中动作使用同一目标。List 和 Grid 的空状态目前支持隔离内的图像与可用的回退图标，远程图标仍待接入，因此两项继续标记为部分兼容。

独立详情和列表行详情共用原生元数据链接控件。宿主在解码时校验目标，点击时仍检查当前视图与扩展启停状态，再打开 HTTP(S) 链接。非 HTTP(S) 目标保持为纯文字，因此两个元数据链接接口仍为部分兼容。

`Form.TextArea` 和 `FormTextArea` 接受 `enableMarkdown`，在原生编辑器中为常见 Markdown 语法着色，并提供 Command-B 与 Command-I。表单回调和提交继续收到未经渲染的文本。完整的语法高亮与快捷键行为仍待验证。

List 与 Grid 的内置搜索按标题及关键词给项目排序，支持跨关键词匹配和忽略重音。分组按最佳匹配排序，扩展可用 `filtering.keepSectionOrder` 固定分组顺序。显示结果和操作重放采用相同顺序。List 与 Grid 的其他交互缺口仍保留为部分兼容。

List 与 Grid 支持按公开项目 ID 指定选中项，并在选择或筛选时将项目 ID 或 `null` 交给 `onSelectionChange`。短寿命来宾会在执行选中动作前重放选择回调，回调仍受现有隔离约束。未提供 ID 时，适配器会生成 UUID。相同视图在筛选和动作重放时复用这些 ID。分页与持续 React 挂载仍待补齐。
