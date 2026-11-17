import Foundation
import WebKit

/// 用真正的 WKWebView 取一次网页标题。
///
/// 为什么需要它：微信公众号对普通 URLSession 请求会重定向到
/// `wappoc_appmsgcaptcha` 验证页，标题为空（实测）。只有会执行 JS、带完整
/// 浏览器行为的 WebView 才拿得到真实标题。普通站点优先走 `LinkTitleFetcher`
/// 的轻量请求，失败才落到这里。
///
/// 同一时刻只允许一个请求：新的请求会先让旧的以 nil 收场。
@MainActor
final class LinkTitleWebFetcher: NSObject, WKNavigationDelegate {

    static let shared = LinkTitleWebFetcher()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = true

    func fetch(url: URL, timeout: TimeInterval = 15) async -> String? {
        finish(nil)
        finished = false

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 1),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        self.webView = webView

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: timeout
            ))
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = #"""
        (function(){
          var meta = document.querySelector('meta[property="og:title"]');
          return ((meta && meta.content) || document.title || '').trim();
        })()
        """#
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            let title = (result as? String).flatMap { SharedLinkURL.cleanedTitle($0) }
            if let title, !LinkTitleParser.isGenericTitle(title) {
                self?.finish(title)
            } else {
                self?.finish(nil)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(nil)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(nil)
    }

    private func finish(_ title: String?) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        let pending = continuation
        continuation = nil
        pending?.resume(returning: title)
    }
}

/// 「自动获取标题」的入口：普通站点先用轻量请求，公众号直接上 WebView。
@MainActor
enum LinkTitleService {

    static func fetch(url: URL) async -> String? {
        let host = url.host ?? ""

        if SharedLinkURL.isWeChatHost(host) {
            if let title = await LinkTitleWebFetcher.shared.fetch(url: url) {
                return title
            }
            return await LinkTitleFetcher.shared.fetch(linkURL: url.absoluteString)
        }

        if let title = await LinkTitleFetcher.shared.fetch(linkURL: url.absoluteString) {
            return title
        }
        return await LinkTitleWebFetcher.shared.fetch(url: url)
    }
}
