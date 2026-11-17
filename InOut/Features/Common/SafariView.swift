import SafariServices
import SwiftUI
import UIKit

/// 用系统 SFSafariViewController 打开外部链接：留在 App 内，但由系统托管
/// （带分享、返回，行为与用户熟悉的浏览器一致）。
///
/// `entersReader` 交给 Safari 的**阅读器模式**：去掉站点自己的导航与广告，只留正文。
/// 它是「尽力而为」—— 页面本身支持阅读器才进得去，不支持就照旧原样显示，
/// 所以打开它不会比关掉更差。
///
/// 但**支持阅读器、却抽得不好**的页面只能靠外面的「网页版」入口救回来：
/// SFSafariViewController 里能不能退出阅读器不由我们决定，所以这里不能写死成 true，
/// 必须由调用方按入口分别决定（见 `WebLinkSheet`）。
struct SafariView: UIViewControllerRepresentable {

    let url: URL
    var entersReader = false

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = entersReader
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(Theme.accent)
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// 「打开哪个链接」+「要不要进阅读器」。
///
/// 两件事装在一个值里，是为了只用**一个** `.sheet(item:)` 就够 ——
/// 详情页上已经有一个对话弹窗，再挂两个链接 sheet 就是同一个视图上三个 sheet。
struct WebLinkSheet: Identifiable {
    let url: URL
    var entersReader = false

    /// 同一个链接的两种打开方式必须是两个 identity，否则 SheetKit 认为「还是那一个」，
    /// 点「网页版」时不会重新弹。
    var id: String { url.absoluteString + (entersReader ? "#reader" : "") }
}

extension View {
    /// 统一的「打开链接」sheet（普通网页）。
    ///
    /// 这里用包装类型，而不是给 `URL` 加 `Identifiable`：给标准库类型做
    /// retroactive conformance 在 Swift 6 下是错误，能避免就避免。
    func safariSheet(url: Binding<URL?>) -> some View {
        let item = Binding<WebLinkSheet?>(
            get: { url.wrappedValue.map { WebLinkSheet(url: $0) } },
            set: { url.wrappedValue = $0?.url }
        )
        return webLinkSheet(item: item)
    }

    /// 需要「阅读器 / 网页版」二选一的页面用这个，自己维护 `WebLinkSheet` 状态。
    func webLinkSheet(item: Binding<WebLinkSheet?>) -> some View {
        sheet(item: item) { value in
            SafariView(url: value.url, entersReader: value.entersReader)
                .ignoresSafeArea()
        }
    }
}
