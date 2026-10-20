import Darwin
import Foundation
import UIKit

/// 「复制运行诊断」的正文拼装。
///
/// 用户拿到的是一段可以整段粘出来的中文，所以在侧载设备上（挂不上调试器，
/// 规则 16）这就是唯一的现场：版本号要能对上 CI 的 run number，各 store 的
/// 条数/更新时间/提示要能说明「是没网、还是解析挂了」。
///
/// **安全边界只有一条：绝不带 Key，也绝不带查询串。**
/// SerpAPI 的 Key 在 URL 查询串里（规则 13），所以这里的接口地址只留
/// `scheme://主机[:端口]`，路径/查询/片段与 `user:pass@` 全部丢掉 ——
/// 全部交给纯函数 `hostOnly`，由 Swift 用例与镜像 19 双向钉住。
/// 密钥本身只报告「存在哪」（钥匙串 / 已降级 / 未保存），不读内容、不打印。
enum DiagnosticReport {

    struct Input {
        var appVersion: String = "-"
        var build: String = "-"
        var systemVersion: String = "-"
        var device: String = "-"
        var appearance: String = "跟随系统"
        var hotCount: Int = 0
        var hotUpdated: String = "未知"
        var hotNotice: String?
        var enrichmentEnabled: Bool = true
        var enrichmentParsed: String = "未解析出结果（已退回接口字段）"
        var favoritesCount: Int = 0
        var reportLines: [String] = []
        var chatProtocol: String = "-"
        var chatModel: String = "-"
        /// 原始接口地址；`make` 内部过 `hostOnly`，调用方不必先洗一遍。
        var chatBaseURL: String = "-"
        var keyStorage: String = "-"
        var searchOrder: String = "-"
        var searchDisabled: String = "无"
    }

    static func make(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("AIHOT 运行诊断")
        lines.append("版本：\(input.appVersion) (\(input.build))")
        lines.append("系统：iOS \(input.systemVersion)")
        lines.append("设备：\(input.device)")
        lines.append("主题：\(input.appearance)")

        lines.append("")
        lines.append("— 热点榜 —")
        lines.append("条数：\(input.hotCount)")
        lines.append("更新时间：\(input.hotUpdated)")
        lines.append("提示：\(input.hotNotice ?? "无")")
        lines.append("网页增强：\(input.enrichmentEnabled ? "开" : "关")，\(input.enrichmentParsed)")

        lines.append("")
        lines.append("— 收藏 —")
        lines.append("条数：\(input.favoritesCount)")

        lines.append("")
        lines.append("— 周报/月报 —")
        if input.reportLines.isEmpty {
            lines.append("暂无数据")
        } else {
            lines.append(contentsOf: input.reportLines)
        }

        lines.append("")
        lines.append("— AI 对话 —")
        lines.append("协议：\(input.chatProtocol)")
        lines.append("模型：\(input.chatModel.isEmpty ? "（未填）" : input.chatModel)")
        // 只留主机名：查询串里可能有 Key，路径也可能带 token
        lines.append("接口：\(hostOnly(input.chatBaseURL))（仅主机名）")
        lines.append("密钥存储：\(input.keyStorage)")
        lines.append("搜索工具顺序：\(input.searchOrder)")
        lines.append("已停用的搜索工具：\(input.searchDisabled)")

        lines.append("")
        lines.append("（此段不含任何 API Key 与完整地址，可直接发给开发者。）")
        return lines.joined(separator: "\n")
    }

    /// 只保留 `scheme://主机[:端口]`；丢 path / query / fragment（SerpAPI 的 Key
    /// 就在查询串里）与 `user:pass@`。非 http(s) 或主机为空 → 「（无法解析）」。
    static func hostOnly(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else { return "（无法解析）" }
        let scheme = trimmed[..<schemeRange.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return "（无法解析）" }

        let rest = trimmed[schemeRange.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        // 凭据只可能在最后一个 @ 之前（主机名/端口里不会出现 @）
        let hostPart: Substring
        if let at = authority.lastIndex(of: "@") {
            hostPart = authority[authority.index(after: at)...]
        } else {
            hostPart = authority
        }
        guard !hostPart.isEmpty else { return "（无法解析）" }
        return "\(scheme)://\(hostPart)"
    }

    // MARK: - 现场采集

    /// 从各 store / 设置里取现场。**只读，不发请求**。
    @MainActor
    static func capture(hot: HotTopicsStore, favorites: FavoritesStore, reports: ReportStore) -> String {
        let info = Bundle.main.infoDictionary
        let appearance = AppSettings.Appearance(
            rawValue: UserDefaults.standard.string(forKey: AppSettings.appearanceKey) ?? ""
        ) ?? .system

        let chatProtocol = AppSettings.aiChatProtocol
        let defaults = UserDefaults.standard
        let baseRaw = defaults.string(forKey: AppSettings.aiChatBaseURLKey(for: chatProtocol)) ?? ""
        let modelRaw = defaults.string(forKey: AppSettings.aiChatModelKey(for: chatProtocol)) ?? ""

        let secret = AIChatSecretStore.shared
        var storageParts: [String] = []
        if secret.key(for: chatProtocol).isEmpty {
            storageParts.append("对话密钥未保存")
        } else if secret.isUsingFallback(for: chatProtocol) {
            storageParts.append("对话密钥已降级到应用内存储")
        } else {
            storageParts.append("对话密钥在钥匙串")
        }
        let fallbackSearch = AppSettings.SearchToolProvider.allCases.filter {
            secret.isUsingSearchFallback(for: $0)
        }
        if fallbackSearch.isEmpty {
            storageParts.append("搜索密钥无降级")
        } else {
            storageParts.append("搜索密钥已降级：" + fallbackSearch.map(\.title).joined(separator: "、"))
        }

        let order = AppSettings.searchToolOrder
        let disabled = AppSettings.searchDisabled
        let disabledText = order.filter { disabled.contains($0) }.map(\.title)
        let reportLines = ReportKind.allCases.map { kind -> String in
            let state = reports.state(for: kind)
            let latest = state.latest?.periodKey ?? "暂无"
            let updated = state.lastUpdated.map { RelativeTime.absoluteShort($0) } ?? "未知"
            let notice = reports.notice(for: kind)?.message ?? "无"
            return "\(kind.title)：最新 \(latest) · 往期 \(state.entries.count) 条 · 更新 \(updated) · 提示 \(notice)"
        }

        let input = Input(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "-",
            build: info?["CFBundleVersion"] as? String ?? "-",
            systemVersion: UIDevice.current.systemVersion,
            device: machineIdentifier,
            appearance: appearance.title,
            hotCount: hot.items.count,
            hotUpdated: hot.lastUpdatedText,
            hotNotice: hot.notice?.message,
            enrichmentEnabled: AppSettings.isEnrichmentEnabled,
            enrichmentParsed: enrichmentSummary(hot.enrichment),
            favoritesCount: favorites.items.count,
            reportLines: reportLines,
            chatProtocol: chatProtocol.title,
            chatModel: modelRaw,
            chatBaseURL: baseRaw,
            keyStorage: storageParts.joined(separator: "；"),
            searchOrder: order.map(\.title).joined(separator: " → "),
            searchDisabled: disabledText.isEmpty ? "无" : disabledText.joined(separator: "、")
        )
        return make(input)
    }

    /// 「解析出 10 条，其中热度 6 条」——说明网页增强到底有没有干活。
    private static func enrichmentSummary(_ enrichment: HotPageEnrichment?) -> String {
        guard let enrichment = enrichment else {
            return "未解析出结果（已退回接口字段）"
        }
        let withHeat = enrichment.ranks.filter { $0.heat != nil }.count
        return "解析出 \(enrichment.ranks.count) 条，其中热度 \(withHeat) 条"
    }

    /// 机型标识（`iPhone15,2`）而不是 `UIDevice.model` 的「iPhone」——
    /// 后者对排查没有信息量，前者能对上屏幕尺寸/内存档位。
    private static var machineIdentifier: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        var identifier = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { break }
            // bitPattern 而不是 UInt8(value)：机型标识是 ASCII，但负值会直接 trap
            identifier.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return identifier.isEmpty ? "未知" : identifier
    }
}
