import Foundation

/// 工具路由：`web_search` → 腾讯云元宝搜索，`read_url` → App 内抓网页。
///
/// 两家协议的工具声明不变；变的只是「谁来执行」。结构性问题（没给工具名 /
/// 未知工具 / 缺参数）在这里**触碰任何网络之前**短路，和以前的链保持同一口径。
struct AIChatToolRouter: AIChatToolExecuting {

    let search: TencentWSARunner
    let reader: WebPageReader

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let name = call.name else {
            // AIChatToolCallAccumulator.result 已经丢掉无名调用 —— 纯防御
            return AIChatToolResult.failure("工具", "这次调用没有给出工具名")
        }

        switch name {
        case AIChatToolName.webSearch:
            guard call.string("query") != nil else {
                return AIChatToolResult.missingArgument(name)
            }
            return await search.execute(call: call)

        case AIChatToolName.readURL:
            guard call.string("url") != nil else {
                return AIChatToolResult.missingArgument(name)
            }
            return await reader.execute(call: call)

        default:
            return AIChatToolResult.failure(name, "没有这个工具")
        }
    }
}
