# 脚本命令

从主搜索打开「管理脚本命令」，添加脚本文件夹。初始搜索范围为空。Keylane 扫描手动添加的文件夹和子文件夹，仅收录带有有效 Keylane 或 Raycast 命令元数据的脚本，并跳过常见依赖目录、符号链接和 `.template` 样例。模块、内置命令和单个脚本均可启用或停用，命令可设置别名和热键。

主搜索中，已配置脚本文件夹内的脚本由脚本命令模块收录。仍可从「搜索文件」查找这些文件。

## 创建脚本

「创建脚本命令」打开启动器内的表单。选择模板、运行模式，填写标题和所需元数据，再按 ⌘↩ 或点「创建脚本」选择保存位置。已有文件会保留。保存后在访达显示脚本。保存位置在搜索范围内时会刷新结果，其他位置可从设置手动添加。

内置模板包括 Shell（Bash、Zsh、sh）、AppleScript、Swift、Python、JavaScript、TypeScript、Go、Ruby、C#（.NET 10）、PHP 和 PowerShell。TypeScript 模板使用支持类型擦除的 Node.js，Go 使用 `go build` 生成临时可执行文件，C# 需要 .NET 10 SDK 或更新版本。脚本也可通过 shebang 指定本机解释器。

## 导入与运行

- 新建脚本写入 `@keylane.*`。必填元数据为 `@keylane.schemaVersion 1`、非空的 `@keylane.title` 和有效的 `@keylane.mode`。现有 `@raycast.*` 脚本可以直接导入。两种前缀可以混用，同名字段以 `@keylane.*` 为准。此前能通过文件名搜到的普通脚本，补齐这三项后即可重新出现，原有别名和热键按路径保留。标题、描述、包名、作者、作者链接、图标、深色图标、工作目录和运行前确认会应用到命令。图标支持 Emoji、本地 PNG/JPEG 和 HTTPS 图像。已配置文件夹中的元数据在重新加载或启动器扫描时更新。
- 支持最多三个文字、密码和下拉参数，以及可选参数和百分号编码。参数直接传给脚本进程。密码字段隐藏输入，启动进程后清空。脚本本身可选择是否输出参数。
- 可为符合条件的脚本启用备用搜索。首个参数需为文字，其余参数均须可选。主搜索无匹配时，选中备用项会把搜索词传给脚本。
- 执行前可调整工作目录与超时。输出最多 256 KB，可从操作菜单复制。
- 有输出的行内命令可加入收藏。运行中的命令支持取消和超时。需要确认的脚本每次运行都会要求确认。

| 模式 | 行为 |
| --- | --- |
| Silent | 运行时收起启动器，结束后显示最后一行标准输出或失败提示。 |
| Compact | 保留启动器，结束后显示最后一行标准输出或失败提示。 |
| Full Output | 打开输出页，逐步显示标准输出和标准错误，支持 ANSI 颜色。 |
| Inline | 将标准输出首行显示在结果右侧，支持 ANSI 颜色。刷新间隔至少 10 秒。先手动运行一次，此后在启动器可见时按间隔刷新，最多自动刷新 10 条。缺少有效间隔或声明参数时按 Compact 运行。 |

「重新加载脚本命令」立即重扫目录。「搜索脚本命令」打开独立列表，支持名称和别名过滤。

参考 [Raycast Script Commands](https://manual.raycast.com/script-commands)、[元数据规范](https://github.com/raycast/script-commands#metadata)、[参数](https://github.com/raycast/script-commands/blob/master/documentation/ARGUMENTS.md)和[输出模式](https://github.com/raycast/script-commands/blob/master/documentation/OUTPUTMODES.md)。
