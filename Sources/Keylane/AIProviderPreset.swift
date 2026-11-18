import Foundation

/// Provider addresses are explicit presets. Secrets are sent only to the selected connection.
struct AIProviderPreset: Identifiable {
    let id: String
    let name: String
    let endpoint: String
    let model: String
    let documentation: String
    let wireProtocol: AIWireProtocol
    var contextTokens: Int? = nil

    var connection: AIConnection {
        AIConnection(name: name, endpoint: endpoint, model: model, contextTokens: contextTokens, wireProtocol: wireProtocol, providerID: id)
    }

    // Names and addresses checked against the OpenCode/models.dev directory, 2026-11-18.
    static let all: [Self] = [
        .init(id: "openai", name: "OpenAI", endpoint: "https://api.openai.com/v1", model: "gpt-6.2-sol", documentation: "https://platform.openai.com/docs/models", wireProtocol: .openAI, contextTokens: 1050000),
        .init(id: "anthropic", name: "Anthropic", endpoint: "https://api.anthropic.com/v1", model: "claude-fable-5-2", documentation: "https://docs.anthropic.com/en/docs/about-claude/models", wireProtocol: .anthropic, contextTokens: 1000000),
        .init(id: "google", name: "Google", endpoint: "https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-4-hydrogen", documentation: "https://ai.google.dev/gemini-api/docs/models", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "openrouter", name: "OpenRouter", endpoint: "https://openrouter.ai/api/v1", model: "openai/gpt-6.2-sol", documentation: "https://openrouter.ai/models", wireProtocol: .openAI, contextTokens: 1050000),
        .init(id: "deepseek", name: "DeepSeek", endpoint: "https://api.deepseek.com", model: "deepseek-flash", documentation: "https://api-docs.deepseek.com/quick_start/pricing", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "groq", name: "Groq", endpoint: "https://api.groq.com/openai/v1", model: "qwen/qwen3.8-27b", documentation: "https://console.groq.com/docs/models", wireProtocol: .openAI, contextTokens: 131072),
        .init(id: "xai", name: "xAI", endpoint: "https://api.x.ai/v1", model: "grok-4.7", documentation: "https://docs.x.ai/docs/models", wireProtocol: .openAI, contextTokens: 500000),
        .init(id: "mistral", name: "Mistral", endpoint: "https://api.mistral.ai/v1", model: "mistral-small-latest", documentation: "https://docs.mistral.ai/getting-started/models/", wireProtocol: .openAI, contextTokens: 262144),
        .init(id: "cerebras", name: "Cerebras", endpoint: "https://api.cerebras.ai/v1", model: "qwen-3.8-27b", documentation: "https://inference-docs.cerebras.ai/models/overview", wireProtocol: .openAI, contextTokens: 131072),
        .init(id: "togetherai", name: "Together AI", endpoint: "https://api.together.xyz/v1", model: "moonshotai/Kimi-K3.1-Pro", documentation: "https://docs.together.ai/docs/serverless-models", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "fireworks-ai", name: "Fireworks AI", endpoint: "https://api.fireworks.ai/inference/v1/", model: "accounts/fireworks/models/kimi-k3p1-pro", documentation: "https://fireworks.ai/docs/", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "perplexity", name: "Perplexity", endpoint: "https://api.perplexity.ai", model: "sonar", documentation: "https://docs.perplexity.ai", wireProtocol: .openAI, contextTokens: 128000),
        .init(id: "cohere", name: "Cohere", endpoint: "https://api.cohere.ai/compatibility/v1", model: "command-a-plus-05-2026", documentation: "https://docs.cohere.com/docs/models", wireProtocol: .openAI, contextTokens: 128000),
        .init(id: "moonshotai", name: "Moonshot AI", endpoint: "https://api.moonshot.ai/v1", model: "kimi-k3.1-pro-highspeed", documentation: "https://platform.moonshot.ai/docs/api/chat", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "moonshotai-cn", name: "Moonshot AI (China)", endpoint: "https://api.moonshot.cn/v1", model: "kimi-k3.1-pro-highspeed", documentation: "https://platform.moonshot.cn/docs/api/chat", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "zhipuai", name: "Zhipu AI", endpoint: "https://open.bigmodel.cn/api/paas/v4", model: "glm-5.3-flashx", documentation: "https://docs.bigmodel.cn/cn/guide/start/pricing", wireProtocol: .openAI, contextTokens: 1000000),
        .init(id: "zai", name: "Z.AI", endpoint: "https://api.z.ai/api/paas/v4", model: "glm-5.3-flashx", documentation: "https://docs.z.ai/guides/overview/pricing", wireProtocol: .openAI, contextTokens: 1000000),
        .init(id: "minimax", name: "MiniMax (minimax.io)", endpoint: "https://api.minimax.io/anthropic/v1", model: "MiniMax-M3.1-Flash", documentation: "https://platform.minimax.io/docs/guides/quickstart", wireProtocol: .anthropic, contextTokens: 1000000),
        .init(id: "minimax-cn", name: "MiniMax (minimax.cn)", endpoint: "https://api.minimax.cn/anthropic/v1", model: "MiniMax-M3.1-Flash", documentation: "https://platform.minimaxi.com/docs/guides/quickstart", wireProtocol: .anthropic, contextTokens: 1000000),
        .init(id: "alibaba", name: "Alibaba", endpoint: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1", model: "qwen3.8-omni-flash", documentation: "https://www.alibabacloud.com/help/en/model-studio/models", wireProtocol: .openAI, contextTokens: 1000000),
        .init(id: "alibaba-cn", name: "Alibaba (China)", endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen3.8-omni-flash", documentation: "https://www.alibabacloud.com/help/en/model-studio/models", wireProtocol: .openAI, contextTokens: 1000000),
        .init(id: "siliconflow", name: "SiliconFlow", endpoint: "https://api.siliconflow.com/v1", model: "zai-org/GLM-5.3-Flash", documentation: "https://cloud.siliconflow.com/models", wireProtocol: .openAI, contextTokens: 1049000),
        .init(id: "siliconflow-cn", name: "SiliconFlow (China)", endpoint: "https://api.siliconflow.cn/v1", model: "deepseek-ai/DeepSeek-V4.1-Flash", documentation: "https://cloud.siliconflow.com/models", wireProtocol: .openAI, contextTokens: 1000000),
        .init(id: "nvidia", name: "Nvidia", endpoint: "https://integrate.api.nvidia.com/v1", model: "minimaxai/minimax-m3.1-flash", documentation: "https://docs.api.nvidia.com/nim/", wireProtocol: .openAI, contextTokens: 262144),
        .init(id: "sambanova", name: "SambaNova", endpoint: "https://api.sambanova.ai/v1", model: "MiniMax-M3.1-Flash", documentation: "https://docs.sambanova.ai/cloud/docs/get-started/supported-models", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "huggingface", name: "Hugging Face", endpoint: "https://router.huggingface.co/v1", model: "thinkingmachines/Inkling-2-Small", documentation: "https://huggingface.co/docs/inference-providers", wireProtocol: .openAI, contextTokens: 1048576),
        .init(id: "vercel", name: "Vercel AI Gateway", endpoint: "https://ai-gateway.vercel.sh/v1", model: "openai/gpt-6.2-astra-fast", documentation: "https://github.com/vercel/ai/tree/5eb85cc45a259553501f535b8ac79a77d0e79223/packages/gateway", wireProtocol: .openAI, contextTokens: 1050000),
        .init(id: "opencode", name: "OpenCode", endpoint: "https://opencode.ai/inference/openai/v1", model: "gpt-6.2-sol", documentation: "https://opencode.ai/v2/docs/console/models/", wireProtocol: .openAI, contextTokens: 1050000),
        .init(id: "opencode-go", name: "OpenCode Go", endpoint: "https://opencode.ai/inference/go/openai/v1", model: "hy4-flash-free", documentation: "https://opencode.ai/v2/docs/console/go/", wireProtocol: .openAI, contextTokens: 1048576),
    ]
}

enum AIWireProtocol: String, Codable, CaseIterable {
    case openAI, anthropic, codex, claudeCode
    var isSubscription: Bool { self == .codex || self == .claudeCode }
}
