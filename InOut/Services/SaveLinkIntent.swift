import AppIntents
import Foundation

/// 快捷指令入口：**收藏一条链接，并直接打开这篇文章**。
///
/// 与 `aihot://add` 是同一个用途，但这是**系统认可的入口**：出现在「快捷指令」
/// App 里，也可以被加进分享表单。它运行在 App 自己的进程里（不需要 App Group），
/// 所以零 entitlement 的侧载分发不受影响。
///
/// 跳转成功后**不弹任何提示**：App 直接切到收藏并 push 文章详情。待打开的文章
/// 走 `AppSettings.pendingOpenLinkURL` 落一次盘 —— 冷启动时 Intent 的 perform
/// 可能比 RootView 还晚，只发通知会漏（见 `RootView.consumeOpenLinkRequest`）。
struct SaveLinkIntent: AppIntent {

    static var title: LocalizedStringResource = "收藏并打开文章"

    static var description = IntentDescription("把网页链接加入「收藏」，然后打开 App 直接进入这篇文章。")

    /// 必须切前台：这条指令的目的就是让用户看到文章。
    static var openAppWhenRun: Bool = true

    /// 用 String 而不是 URL：快捷指令里分享输入经常是文本（或整段「标题 + 链接」），
    /// `URL` 参数会在动作校验阶段就失败，用户只看到「没有成功导入」。
    @Parameter(title: "链接", description: "要收藏并打开的网页地址，也可以直接粘贴一段含链接的文字")
    var url: String

    @Parameter(title: "标题", description: "可选；留空时用网页标题或域名")
    var title: String?

    static var parameterSummary: some ParameterSummary {
        Summary("收藏并打开 \(\.$url)") {
            \.$title
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // 分享输入可能是纯 URL，也可能是一段「标题 + 链接」的文字；两种都捞一次。
        guard let normalized = SharedLinkURL.normalized(url)
                ?? SharedLinkURL.firstURL(in: url).flatMap({ SharedLinkURL.normalized($0) })
        else {
            throw SaveLinkIntentError.invalidURL
        }

        let store = FavoritesStore()
        let link = SavedLink(url: normalized.absoluteString, title: title)
        // 已经收藏过也照样打开它 —— 这不是错误。
        store.add(link: link)

        AppSettings.pendingOpenLinkURL = link.url
        NotificationCenter.default.post(name: .aihotOpenLink, object: nil)
        return .result()
    }
}

enum SaveLinkIntentError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "链接无效：只支持公开的 http(s) 网页。"
    }
}

extension Notification.Name {
    /// 进程内通知：App 已经在运行时让 RootView 立刻消费待打开的链接。
    static let aihotOpenLink = Notification.Name("aihot.openLink")
}

/// 让上面的 intent 自动出现在快捷指令列表里（不用用户手动拼一个）。
struct InOutAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SaveLinkIntent(),
            phrases: [
                "收藏并打开 \(.applicationName) 的文章",
                "保存链接到 \(.applicationName)",
            ],
            shortTitle: "收藏并打开",
            systemImageName: "bookmark"
        )
    }
}
