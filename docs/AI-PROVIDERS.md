# AI 提供商与模型管理

AI 设置的「模型与提供方」提供 API Key、订阅 CLI、Ollama 和自定义 OpenAI 兼容配置。Quick AI、AI Chat、内置及自定义 AI 命令和询问文件复用 `AIRuntime`。

## API Key

选择提供商、输入 Key 并验证后保存。接口地址由预设提供。模型 ID 留空采用预设，也可以修改。验证会发送简短测试消息并产生提供方用量。预设覆盖 OpenAI、Anthropic、Google、OpenRouter、DeepSeek、Groq、xAI、Mistral、Cerebras、Together AI、Fireworks、Perplexity、Cohere、Moonshot、Zhipu、Z.AI、MiniMax、Alibaba、SiliconFlow、NVIDIA、SambaNova、Hugging Face、Vercel AI Gateway 和 OpenCode，并包含部分服务的国内与国际地址。

名称和地址参考 [OpenCode](https://opencode.ai/docs/providers/) 和 [models.dev](https://models.dev/)。29 条预设使用固定地址，默认模型仅为初始建议，其可用性由用户账户的验证结果确定。需要云资源标识、区域或多项凭据的 Azure、Bedrock、Vertex 等入口尚未提供一键接入。

Anthropic 和 MiniMax 的 Anthropic 接口使用 Messages 协议。Google 使用其官方 OpenAI 兼容入口。其他预设走兼容协议。密钥写入本机钥匙串，按连接和端点隔离。批量加入仅适用于与已保存连接完全一致、未覆盖临时密钥的发现结果；编辑地址或临时密钥后，先保存对应连接再重新同步。同步发现的多个模型共享凭据，移除其中一个模型时保留其他模型需要的密钥。

## 本地订阅

ChatGPT 使用 Codex CLI，Claude 使用 Claude Code。用户在 CLI 中完成登录，再在设置中启用。Advanced 可选择 CLI 路径、账户目录和模型，留空路径使用标准安装位置。模型同步及账户检查均按用户动作触发。

Codex 使用 app-server 的初始化、账户、模型目录、额度和会话接口。会话为临时会话，关闭 shell、应用工具、hooks 和图像工具；Claude 以无工具、无 MCP、无会话持久化的 print 模式运行。每次生成前核对账户。子进程拥有独立临时工作目录、输出上限、超时和取消生命周期，关闭请求后终止对应进程。

Show Usage 展示 CLI 返回的账户额度窗口、重置时间和可用重置次数。用量结果附带查询时的账户标识。用户确认后，在同一个 CLI 进程内重新核对当前账户、已保存账户与确认的账户一致，才使用幂等键申请重置并重新读取额度。账户变化会清除旧用量，要求重新连接账户、刷新并再次确认。Claude CLI 当前没有公开的账户总额度接口，界面提示去账户页面查看。较旧 CLI 缺少接口时会提示更新。Claude print 模式返回完整回复，Codex 使用流式回复。

## Ollama

Host 默认 `http://127.0.0.1:11434`，同步通过 `/v1/models` 获取已有模型。用户选择模型后加入目录。安装入口指向 Ollama 官方网站。允许本机 HTTP 和远程 HTTPS。Ollama 可以转发云模型，实际数据目的地取决于所选 Host 和服务端模型配置。

## 自定义提供商

打开 `~/.config/keylane/ai/providers.yaml` 和旁边的模板。支持 `providers`、`api_keys`、`additional_parameters`、模型 `id/name/provider/context/abilities`。YAML 解析由 MIT 许可的 Yams 6.2.2 提供，限制文件大小。YAML 的 `tools` 段尚未接入，Raycast 专属工具服务不在本阶段范围内。

返回设置窗口后自动重新载入发生变化的文件。提供商与模型标识用 UTF-8 长度前缀组合，避免标识本身包含分隔符时碰撞。导入前拒绝重复连接 ID，旧版本遗留的重复目录重载不再触发 Dictionary 崩溃。解析或校验失败保留之前的有效目录，错误信息避免引用含密钥的源代码行。文件中的 Key 会写入钥匙串，用户填写的原文件仍包含这些 Key，应自行保持私密。新建目录和文件使用 0700、0600 权限。删除或关闭提供商请从 YAML 中编辑，模型显示开关可直接在管理列表中调整。

## 模型管理与验收

管理列表支持搜索、按提供商或模型品牌分组、折叠和显示开关。上下文长度由提供方配置提供；速度和智能评分缺乏统一可靠来源时显示未提供。隐藏模型只改变选择器可见性，既有会话和默认绑定仍按稳定连接 ID 工作。

自动化覆盖原生 Anthropic 流式/完整响应、兼容提供方请求、账户目录、模型列表、额度、重置、账户隔离、取消、共享密钥查询、显示开关和 YAML 校验。CLI 使用合成可执行文件，HTTP 使用 URLProtocol 合成响应。真实账户登录、真实配额、各厂商联网成功、窗口布局及长列表性能仍待安装版实机验收。依赖 #181 的模型目录，并已整合 #182 的聊天设置。

## PR #183 审查回归

- 不同发现端点不能将模型批量绑定到旧连接或旧凭据；临时密钥不会成为已保存批量模型的凭据。
- `a::b / c` 与 `a / b::c` 得到不同稳定标识；重复输入在钥匙串操作前失败且不发布目录，旧重复记录可安全重载。
- 合成 CLI 在读取用量后切换账户，旧确认不会发出 consume 请求；重连后仍须刷新并确认新的账户标识，才允许合成重置。测试不使用真实重置额度。
- Anthropic 流式及完整响应的 usage 带有嵌套 cache_creation 与字符串 service_tier 时，仍正确报告输入与输出 token。缺失字段不会伪造 0 用量。
