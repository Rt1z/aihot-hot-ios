import Foundation

/// `web_search` 的执行者：腾讯云元宝搜索。
///
/// 没有多提供方、没有顺序与回退 —— 只有一家。凭据缺失时不发网络请求，
/// 直接返回一句能照着做的配置提示。
struct TencentWSARunner: AIChatToolExecuting {

    let config: TencentWSAConfig
    let api: TencentWSAAPI

    init(config: TencentWSAConfig, api: TencentWSAAPI = .shared) {
        self.config = config
        self.api = api
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let query = call.string("query") else {
            return AIChatToolResult.missingArgument(AIChatToolName.webSearch)
        }

        switch await api.search(config: config, query: query) {
        case .success(let text):
            return (AIChatToolResult.clamp(text), false)
        case .failure(let message):
            return AIChatToolResult.failure(AIChatToolName.webSearch, message)
        }
    }
}
