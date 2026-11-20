# 翻译

在主搜索运行「翻译」，输入或粘贴原文。输入结束约 450 ms 后自动翻译。左侧编辑原文，右侧显示译文，语言选择器支持中文、英文名称和语言代码搜索。内置 28 种常用语言，实际可用语言以所选提供商及账户为准。

设置入口为「设置 → 翻译」。首次使用选择提供商并配置凭据，或选择已有 AI 模型。模型菜单遵循统一目录的可见性规则，隐藏未选模型；已选中的隐藏模型仍保留，以免破坏现有绑定。

原文编辑器的提示文字按实际可见文本显示：输入法组字一出现就隐藏提示；未提交的组字不会发起翻译，提交后再触发请求。

| 提供商 | 配置 |
| --- | --- |
| AI 模型 | 启用 AI，并选择已有模型，或跟随 AI 命令默认模型 |
| Google Cloud Translation | 启用 Cloud Translation Basic API 的 API Key |
| Microsoft Translator | Azure Translator 密钥，以及资源要求的区域 |
| 有道翻译 | 自然语言翻译应用 ID 与应用密钥 |
| 百度翻译 | 通用翻译应用 ID 与密钥 |

提供商凭据保存在 `org.keylane.translator` 钥匙串项目。原文和译文保留在当前会话中，偏好只保存语言、提供商、AI 模型 ID 和自定义命令。AI 翻译通过公共 `AIRuntime` 调用，可使用已配置的 API、本地模型和订阅连接。翻译请求在编辑、换语言、隐藏或禁用模块时取消，结果按请求版本核对后显示。AI 译文在生成时逐步显示；其他模型的目录、可见性或默认设置更新不会重启当前翻译。单次翻译最长等待 120 秒，超时会取消请求并显示重试提示。订阅 CLI 的账户变化、配置和服务错误会显示对应说明。固定提供商的请求使用 HTTPS，拒绝重定向，响应上限为 1 MiB。

## 交互

- `⌘ Return` 执行设置中的主要操作，复制译文或粘贴到前一个应用。
- `⌥ ⌘ Return` 粘贴译文，`⌥ Return` 复制原文。
- `⌘ S` 交换语言，并将译文放入原文。
- `⌘ P` 打开目标语言，`⇧ ⌘ P` 打开源语言。
- `⌘ K` 打开宿主操作菜单。AI Chat 可用时，可将原文和译文作为新聊天草稿继续处理。
- 原文编辑器内按 Esc 清空输入，再按 Esc 返回。中文输入法的未提交文本会留在编辑器内。
- 输入法组字时隐藏空白提示，提交组字后再翻译，避免提示与文字重叠。
- 麦克风按钮按需申请麦克风和语音识别权限，将语音转为原文。两侧扬声器使用 macOS 的语音朗读能力。

设置中可创建固定语言对命令，配置名称、别名、快捷键和启用状态。输出行为可选「在 Keylane 中打开」或「替换选中文字」。自动替换在准备粘贴以及目标应用激活后、发送粘贴快捷键前分别检查命令、目标应用、原字段、选区范围和选中文字；不匹配时停止粘贴。隐藏窗口会取消待完成的翻译。使用选中文字与跨应用粘贴依赖对应系统权限。普通命令与自定义命令均支持主搜索备选命令。

## 验证

`swift test --filter TranslationTests` 验证官方请求格式、签名、Unicode 编码、响应和错误处理。`bash scripts/verify-translator.sh` 用隔离偏好和模拟 HTTP 服务验证防抖、取消、重新打开、交换语言、错误重试、共享 AI 运行层、流式输出、部分译文取消、超时重试与自定义命令持久化。

真实服务调用需要有效账户配置。自动化验证使用模拟响应，实机语音、选中文字与粘贴需在授予系统权限后验证。

## 参考

- [Raycast Translate 手册](https://manual.raycast.com/translate)
- [Google Cloud Translation v2](https://docs.cloud.google.com/translate/docs/reference/rest/v2/translate)
- [Microsoft Translator v3](https://learn.microsoft.com/en-us/azure/ai-services/translator/text-translation/reference/v3/translate)
- [有道文本翻译](https://ai.youdao.com/DOCSIRMA/html/trans/api/wbfy/index.html)
- [百度通用翻译](https://fanyi-api.baidu.com/doc/21)

## 翻译速度

Codex 订阅翻译请求使用 `low` 推理强度，跳过与翻译无关的插件、技能和项目说明启动，并显式关闭已配置的 MCP 服务。这些设置仅限翻译子进程，不修改账户配置文件，也不改变 Quick AI、AI Chat 或文件问答的请求设置。

连续编辑时复用空闲的订阅连接，每次翻译仍创建独立的临时会话，并在发送原文前重新核对账户。连接最多复用 8 次，闲置 60 秒或隐藏翻译页后释放；请求取消或失败会丢弃该连接。迟到的旧会话事件不会进入新译文。连接复用同时保留尚未读完的数据，避免跨请求拆分的通知或 UTF-8 字符破坏后续解析。

本机 2026-11-20 的一次 GPT-6 Luna 三句测试耗时分别为 15.9、16.2、15.0 秒，均返回译文并结束加载。此前同机单句测试约 25–29 秒；这些并非严格控制网络与服务负载的对照实验，不能当作稳定提速比例或秒回保证。

参考：[Codex App Server](https://developers.openai.com/codex/app-server) 与 [配置结构](https://developers.openai.com/codex/config-schema.json)。
