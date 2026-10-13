import Foundation

/// 五家搜索工具的回退链：设置里的**顺序即优先级**，按顺序逐家执行
/// `web_search` / `read_url`，第一家成功即返回；失败（Key 无效 / 429 / 网络 /
/// isError）自动换下一家；**全部失败时回传第一家的错误**（最好排查 ——
/// 第一顺位是用户最可能配好的那家）。
///
/// 与 `AIChatModel.makeSearchChain()` 的分工：链持有**一次发送的完整快照**
/// （顺序 / 停用 / Key / 各家 runner），send 中途改设置不影响进行中的对话。
///
/// 三层过滤（`eligibleProviders` 是纯函数，镜像 15 钉）：
/// 1. 停用的跳过；
/// 2. `read_url` 跳过不支持读网页的家（SerpAPI / Serper 能力矩阵 ✗）—— 自动跳过，
///    用户不用管；
/// 3. 必填 Key 却没填的跳过（AnySearch 可匿名，空 Key **保留**）。
///
/// 结构性问题（没给工具名 / 未知工具 / 缺参数）在触碰任何提供方**之前**短路：
/// 各家对这些情况返回逐字相同的消息，走完链零信息量。
struct SearchToolChain: AIChatToolExecuting {

    /// 全量顺序快照（含停用/没 Key 的家 —— 出错时能解释「谁没参与、为什么」）。
    let order: [AppSettings.SearchToolProvider]
    let disabled: Set<AppSettings.SearchToolProvider>
    let keys: [AppSettings.SearchToolProvider: String]
    let runners: [AppSettings.SearchToolProvider: any AIChatToolExecuting]

    /// 纯函数：按三层过滤留下这次该试的家，**保持用户顺序**
    /// （与 `tools/logic_tests.py` 的 `eligible_providers` 对应；Swift 是权威）。
    static func eligibleProviders(
        order: [AppSettings.SearchToolProvider],
        disabled: Set<AppSettings.SearchToolProvider>,
        keys: [AppSettings.SearchToolProvider: String],
        tool: String
    ) -> [AppSettings.SearchToolProvider] {
        let needsReadURL = tool == AIChatToolName.readURL
        return order.filter { provider in
            if disabled.contains(provider) { return false }
            if needsReadURL && !provider.supportsReadURL { return false }
            if provider.requiresKey {
                let key = (keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty { return false }
            }
            // AnySearch 不要求 Key：留空照样参与（匿名合法）
            return true
        }
    }

    /// 一个可试的家都没有时的可执行提示（不发任何网络）。
    static func emptyEligibleMessage(tool: String) -> String {
        if tool == AIChatToolName.readURL {
            return "没有能读网页的工具：SerpAPI、Serper 只支持搜索，其余家要么停用要么没填 Key。"
                + "到「设置 → AI 对话 → 搜索工具」启用 AnySearch / Tavily / Exa 之一（AnySearch 可匿名）。"
        }
        return "没有可用的搜索工具：搜索工具全被停用，或都没填 Key。"
            + "到「设置 → AI 对话 → 搜索工具」启用一家并填好 Key；AnySearch 留空 Key 即用匿名。"
    }

    /// 单家 runner 工厂：发送用的回退链（`AIChatModel.makeSearchChain`）与
    /// 设置页的「测一下」共用这一个 switch —— 新增提供方时两处都不会漏。
    static func makeRunner(
        for provider: AppSettings.SearchToolProvider,
        apiKey: String
    ) -> any AIChatToolExecuting {
        switch provider {
        case .anySearch: return AnySearchToolRunner(apiKey: apiKey)
        case .tavily: return TavilyToolRunner(apiKey: apiKey)
        case .serpapi: return SerpAPIToolRunner(apiKey: apiKey)
        case .exa: return ExaToolRunner(apiKey: apiKey)
        case .serper: return SerperToolRunner(apiKey: apiKey)
        }
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        // 结构短路：不查任何提供方（各 runner 自己的校验保留为防御）
        guard let name = call.name else {
            // AIChatToolCallAccumulator.result 已经丢掉无名调用 —— 纯防御
            return AIChatToolResult.failure("工具", "这次调用没有给出工具名")
        }
        switch name {
        case AIChatToolName.webSearch:
            guard call.string("query") != nil else {
                return AIChatToolResult.missingArgument(name)
            }
        case AIChatToolName.readURL:
            guard call.string("url") != nil else {
                return AIChatToolResult.missingArgument(name)
            }
        default:
            return AIChatToolResult.failure(name, "没有这个工具")
        }

        let eligible = Self.eligibleProviders(order: order, disabled: disabled, keys: keys, tool: name)
        guard !eligible.isEmpty else {
            return AIChatToolResult.failure(name, Self.emptyEligibleMessage(tool: name))
        }

        var firstError: (text: String, isError: Bool)?
        for provider in eligible {
            // 取消了就不再发下一家（停止按钮绝不触发额外请求）
            if Task.isCancelled { break }
            guard let runner = runners[provider] else { continue }
            let outcome = await runner.execute(call: call)
            if !outcome.isError {
                return outcome
            }
            // 全败时回传第一家的错 —— firstError 永不覆盖
            if firstError == nil {
                firstError = outcome
            }
        }
        // 一步都没走成（或全被取消）才没有 firstError
        return firstError ?? AIChatToolResult.failure(name, "请求已取消")
    }
}
