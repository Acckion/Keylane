# 内置模块迁移

## 集成范围

架构工作树已接入 `dev` 的全部内置入口。应用、文件搜索与文件 AI、剪贴板、便笺、快捷链接、计算器、系统工具、日历、联系人、词典、Emoji、Apple 快捷指令、窗口切换、菜单搜索、系统设置搜索和截图均通过模块注册。设置仍使用原有界面，沿用已有命令 ID、数据库、设置键和快捷键。

## 接入契约

- 在应用组合点注册 `LauncherModule`。目录校验检查模块、命令、页面、设置页和命名空间，注册时不构建页面或启动监听。设置页工厂和定位锚点由模块提供。
- 搜索、热键和菜单按 `CommandID` 调用同一执行器。动态结果保留 `app:`、`shortcut:` 和 `system-setting:` 路由，应用路径继续作为收藏、别名和使用次数的键。文件未完成搜索时拒绝执行打开。
- 根搜索复用缓存和评分规则。模块只发布影响候选或排名的变化，快捷指令图标与运行状态单独更新展示。文件结果按当前类型筛选后复用，收到新结果时清除缓存。
- 启动器把当前页的查询、方向键、回车、菜单和退出交给登记的处理器。宿主统一处理页面首次进入、隐藏和恢复。每次离开活动页面只执行一次清理，并释放页面预览。Quick Look 抢占焦点时允许预览窗口继续使用。
- 剪贴板关闭采集后停止轮询，历史仍可打开。日历关闭后停止监听与定时刷新。剪贴板采集、文件索引和日历菜单栏独立于页面生命周期。

## 验证

核心测试覆盖重复 ID、失效路由、持久化兼容和排名。注册表集成测试覆盖惰性注册、三个命令来源、实时可用性和服务启停。系统集成脚本使用临时文件、命名剪贴板及模拟数据，并通过系统服务验证文件变更、菜单栏和截图操作。实机还需复验真实权限下的窗口与菜单执行、输入法、滚动、Quick Look 和持续 CPU / 内存。

脚本模块在启用时监听已配置目录，合并文件变更通知后在后台更新目录。行内脚本在首次手动执行后按到期时间刷新，启动器隐藏时暂停并取消当次后台运行。手动运行优先于行内刷新，后台输出相同时不刷新界面。

## 设置页组件

侧栏按 `LauncherModule.origin` 分组。Keylane 宿主登记为 `.application`，功能模块默认为 `.builtInExtension`。将来接入的第三方模块可登记为 `.installedExtension`，有设置页时才显示该分组。内置扩展可以提供专属设置页，只有命令配置时可使用共用命令列表。

「应用程序」和「截图」是设置页接入样例。模块登记页面、搜索项及所需的标题栏开关，设置窗口负责侧栏、搜索、页头、滚动和历史。设置窗口只订阅路由、外观与窗口反馈。页面通过 `ViewObservation` 订阅自己渲染的字段。

常规分组使用 `SettingsCard` 或 `SettingsGroup`，说明文字使用 `SettingsCaption`。独立的纯图标操作使用 `SettingsIconButton`，默认、悬停、按下和禁用时均有背景。可搜索的分组将登记用的 `SettingsItem` 直接传给 `SettingsCard(anchor:)`。命令列表使用 `CommandSettingsList`，条目通过 `CommandSettingsEntry` 的 `CommandID` 接口接入别名和热键。行高、分隔线和列对齐均由列表管理。应用别名继续使用应用路径。长列表保留惰性布局、稳定的行 ID 和后台缩略图缓存。功能专属控件可以放进共用卡片，例如截图列数预览。

文件搜索、剪贴板、日历和快捷指令也沿用这些组件与定位方式。文件索引和剪贴板历史的统计分组独立订阅各自的状态。快捷指令长列表使用惰性行布局，保留原有行高和快捷键编辑行为。通用、菜单栏、便笺、快捷链接、高级和关于页复用同一套搜索锚点。

快捷键总览使用模块登记的命令目录。动态条目通过 `dynamicCommandSettings` 提供数据、需要观察的字段和行工厂，并与模块专属设置页共用 `CommandSettingsEntry`。应用路径别名与命令热键 ID 分开传入。浏览总览时只读取展开分组的动态目录，搜索时按名称、别名或快捷键查找。静态与动态命令共用一组列标题和列表分隔线。

设置窗口和入口遵循 Apple 的 [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) 指南。Keylane 使用 AppKit 管理独立设置窗口，SwiftUI 构建内容。标签对齐和分组参考 [SwiftUI Form](https://developer.apple.com/documentation/swiftui/form) 与 [WWDC22 的 macOS 表单演示](https://developer.apple.com/videos/play/wwdc2022/10052/?time=997)。布尔偏好使用开关，命令列表使用复选框，带预览的选项提供明确的选中边框。验收设置页时检查深浅外观、键盘焦点、长标题和设置搜索跳转。

## 启动器界面组件

- 普通结果用 `ResultListRow`。主搜索使用 `.root` 布局，二级列表使用标准布局。带选中状态的列表用 `SelectableResultList` 管理滚动定位。主搜索和文件结果用 `CommandID` 保持选中项，结果重排后按同一 ID 执行。文件类型随查询结果发布，筛选与结果行复用同一份元数据。
- 左右分栏使用 `ResultDetailLayout`，预览和信息由 `ResultDetailPane` 独立滚动。Quick Look 保留自身滚动，固定尺寸的图片预览直接填入预览区。页面提供内容、查询和预览生命周期。便笺使用独立的编辑分栏。
- 截图与 Emoji 通过 `ResultGrid` 显示内容，用 `ResultGridSelection` 处理方向键和结果变化。模块负责分组、图片和激活动作。
- 搜索页浮动筛选使用 `ResultTypeFilter`。底部菜单与筛选共用 `LauncherMenuRow` 和 `LauncherMenuSurface`，宿主管理浮动菜单的打开、关闭和焦点归还。应用与文件动作由模块登记。

- 二级页面通过 `LauncherPage.ContentPlacement` 声明内容与浮动栏的位置。列表中的可激活结果用 `ResultListButton` 保持点击动作和滚动目标的 ID 一致。宿主只观察会改变页头、主按钮或操作菜单的状态，列表、详情和便笺编辑器各自观察自己的内容。
- 创建类命令使用 `LauncherPage.ContentPlacement.form`，由 `LauncherCreationForm` 提供返回按钮、可选顶部操作区域和滚动表单。字段用 `LauncherCreationField` 对齐，输入控件可用 `LauncherCreationControl` 统一描边。命令负责绑定、校验和提交，底栏继续由启动器宿主管理。
