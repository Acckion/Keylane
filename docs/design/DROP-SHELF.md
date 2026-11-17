# 原生暂存架：官方调查与待确认设计

状态：调查完成，关键产品选择待答复；尚未实现或实机验收。
调查日期：2026-11-17。基线：origin/dev dbe3e727bd9c575871da8de51e96774dfc2de502。
工作树：/tmp/keylane-drop-shelf；分支：feat/drop-shelf。

## 范围

本次仅为 Keylane 实现 Dropover 式本地暂存与真实跨应用拖放，顺序为官方调查、底层能力、界面。未涉及 Launcher 草稿 #148、第二阶段设计、云分享、付费服务、第三方代码或素材、安装覆盖、系统安全设置变更。

主检出 /Users/acckion/Dev/Active/KeylaneProject/Keylane 的 README.md 有用户修改，保持原样。检查本地 Git 分支/worktree、Sources、Tests 和 docs，未发现同范围实现。可访问开发对话的近期摘要显示正在做扩展兼容、相机、计算器和快捷键；其中提到 Dropover 的附件路径不是 Dropover 开发任务。未读取原始会话文件。仓库没有 .agents/skills；已读最新 dev 的 AGENTS.md、Package.swift、LAUNCHER-ARCHITECTURE.md、UI-ACCEPTANCE.md 和相关原生实现。

## 官方行为与来源

以下为公开资料的摘要，不是 Keylane 已实现能力。

- [Dropover 官网](https://dropoverapp.com/)：浮动暂存架容纳文件、文件夹、文字、链接与图片；支持摇晃激活、菜单栏入口及预览等。这里只以核心暂存为研究范围。
- [官方 FAQ](https://dropoverapp.com/faq)：Finder 输入仅保留文件引用；同卷拖出可能默认移动，可设置为复制。放入暂存架不自动上传。
- [固定暂存架帮助](https://dropoverapp.com/kb/pinned-shelves)：固定与最近暂存架具有不同的保留规则，源文件不可访问会影响恢复。不能由“暂存”一词推断重启保留策略。
- [官方技巧](https://dropoverapp.com/tips)：菜单栏可以作为拖入入口。
- [5.2.5 变更](https://dropoverapp.com/whats-new/5.2.5)：提到拖出后保持窗口选项，以及外部文件变更和临时文件清理改进；这些是需要显式验证的边界。
- [Apple NSFilePromiseReceiver](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver)：通过原生 pasteboard 读取文件承诺，接收可涉及多个文件，不能假定一个 receiver 恰好对应一个文件。
- [Apple receivePromisedFiles](https://developer.apple.com/documentation/appkit/nsfilepromisereceiver/receivepromisedfiles(atdestination:options:operationqueue:reader:))：异步交付回调；同次拖动的接收器使用相同目的目录，需处理错误与不完整文件。
- [Apple 文件承诺示例](https://developer.apple.com/documentation/appkit/supporting-collection-view-drag-and-drop-through-file-promises)：原生拖入/拖出接入参考，仅参考公开 API 契约。
- [Apple 文件 URL 读取选项](https://developer.apple.com/documentation/appkit/nspasteboard/readingoptionkey/urlreadingfileurlsonly)：将本地文件和普通链接分开解析。

Apple 文档的 HTML 为 JavaScript 页面；NSFilePromiseReceiver 与 URL 选项已通过官方提供的 Markdown 链接读取。实施时继续核对本机 SDK 的签名与拖动操作协商契约。

## 必须确认的选择

AGENTS.md「关键问题没明确，必须先问」要求：有多种合理解释且改变入口、数据行为或验收时，答复前仅推进独立部分。本次已询问：

1. 第一版入口是否包含摇晃激活，还是菜单栏拖入和 Keylane 命令。
2. 会话内暂存还是重启恢复。二者改变数据写盘和关闭行为。
3. 拖出始终复制还是复现系统移动规则。建议始终复制，以满足不意外移动源文件的要求；此项不是已经获批的产品决定。

未收到答复前，不落地这些相关的产品代码。界面关闭是否仅隐藏也应随生命周期一起明确，不把 Esc 或关闭窗口默认为清空内容。

## 基于现有架构的技术方案草案

- 新模块通过 LauncherModuleRegistry 注册命令、设置和服务；不在主搜索分支直接插入业务逻辑。MenuBarRegistry 管理原生状态项，现有实现尚无拖入扩展点；若批准菜单栏拖入，再增加有生命周期清理的局部扩展点。
- 独立 AppKit NSPanel 承载暂存架，SwiftUI 提供内容、空态、加载和失败反馈。它独立于启动器失焦隐藏；切应用后仍需可拖出。复用现有外观配置，不建立第二套全局快捷键或菜单栏管理器。
- 控制器区分外部文件引用、Keylane 所有的临时文件、文字和普通链接；UI 行标识不使用显示名称。外部文件绝不进入清理器；临时目录清理只能针对本次任务创建并记录的路径。
- 输入先按 pasteboard item 处理优先级，避免同一文件的 URL、文字路径和图像多种表示重复加入。可读类型协商不等于实际接收成功；无法加载的表示需给出逐项反馈。
- Finder URL 保留引用并在拖出前重新检查存在性和可读性；不得静默用旧文件内容替代。改名追踪策略、是否持久 bookmark 随生命周期选择确定；不能把保存 URL 当作永久权限。
- 文件承诺写入每次拖动独立的私有目录。每批导入具有身份和代次；取消或清空撤销提交资格。取消队列不能保证提供方停止写入，迟到回调不得复活条目，目录需等写入结束再清理。失败不能报告成功，支持部分成功的明确结果。
- 原始文字/图片可在用户拖出到 Finder 时以临时文件或文件承诺交付，同时为编辑器保留原生类型。图片和承诺输入必须有大小/资源上限与磁盘不足反馈；不得下载普通网页 URL 或上传数据。
- 拖出由 NSDraggingSource 协商允许操作。是否只提供 copy 等待答复；无论采用何种策略，不在拖动结束回调自行移动/删除源文件。取消或目标拒绝必须保留架上条目。
- 重复拖入同一 URL 与相同内容的处理必须可预测：建议同一架按规范 URL/内容标识去重，显示已存在反馈；不以文件名去重。拖动会话中的重复 perform 回调必须幂等。
- 权限按直接用户拖入的可用权限尝试，不触发全盘访问或自动化授权。拒绝访问保持条目错误可见，不自动更改系统设置。若重启恢复获批，再设计受限的持久内容与 bookmark 失效处理。

## 验收矩阵（均待执行）

自动化夹具只能放在独立临时目录，使用命名 pasteboard；不读取用户真实剪贴板或私人文件。

| 场景 | 断言 | 证据级别 |
| --- | --- | --- |
| 文件/目录、多文件、同名不同路径 | 准确类型与顺序；源未移动或删除 | 合成 + Finder 实机 |
| 文本、URL、浏览器图片 | 无重复表示；编辑器/文件目标可消费 | 合成 + 安全本地目标实机 |
| 文件承诺、多文件承诺、延迟和失败 | 无未完成条目伪成功；逐项错误 | 可控提供方 + 实机提供方 |
| 取消接收、清空、关闭后迟到回调 | 不复活；清理不越界 | 合成竞态 + 实机取消 |
| 重复加入/重复执行 | 幂等；明确反馈 | 合成 + 实机 |
| 源文件修改、改名、删除 | 拖出前重新校验；不静默使用旧内容 | 合成 + Finder 实机 |
| 权限不足、磁盘不足/加载失败 | 可理解失败、可重试；无权限设置变更 | 合成；真实提示另记 |
| Finder 拖出、编辑器拖出、目标拒绝/取消 | 遵循确认的 copy/move 规则；失败保留暂存 | 必须 Mac 实机 |
| 切应用、返回架、Esc、焦点与键盘导航 | 状态与内容保持一致；Esc 不意外丢数据 | 必须 Mac 实机 |
| 深浅色、减少透明度、多屏/全屏 | 可读、可聚焦、窗口可达 | 必须 Mac 实机 |
| 退出与重启 | 遵循获批生命周期；不碰源文件 | 跨进程 + 实机 |

完成后运行 AGENTS.md 基本检查、相应模块与菜单栏集成检查、专用暂存架检查，并记录构建签名与真实验收边界。不把模拟拖放当成跨应用实机通过。

## 当前交付状态

仅完成研究和方案草案。尚无底层/界面代码、构建/测试结果、真实拖放验收、推送或 PR。待上述选择答复后实施。不会创建 PR/Issue，除非确认创建身份为 AcckionCab；若仅有 Acckion，交付分支和正文供主助手创建草稿 PR。
