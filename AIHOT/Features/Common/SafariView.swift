import SafariServices
import SwiftUI
import UIKit

/// 用系统 SFSafariViewController 打开外部链接：留在 App 内，但由系统托管
/// （带分享、阅读器、返回，行为与用户熟悉的浏览器一致）。
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(Theme.accent)
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

extension View {
    /// 统一的「打开链接」sheet。
    ///
    /// 这里用包装类型，而不是给 `URL` 加 `Identifiable`：给标准库类型做
    /// retroactive conformance 在 Swift 6 下是错误，能避免就避免。
    func safariSheet(url: Binding<URL?>) -> some View {
        let item = Binding<SafariItem?>(
            get: { url.wrappedValue.map { SafariItem(url: $0) } },
            set: { url.wrappedValue = $0?.url }
        )
        return sheet(item: item) { value in
            SafariView(url: value.url)
                .ignoresSafeArea()
        }
    }
}

private struct SafariItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
