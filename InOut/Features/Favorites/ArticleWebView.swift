import SwiftUI
import UIKit
import WebKit

/// 导入文章的内嵌阅读器。
///
/// **为什么这里用 WKWebView**：微信公众号对普通 URLSession 请求会返回验证页
/// （`wappoc_appmsgcaptcha`），标题和正文都拿不到；而真正的浏览器能打开文章。
/// 内嵌 WKWebView 既解决「全文 + 原样式」，也顺便把真实标题读回来
/// （`document.title` / `og:title`），修复导入时标题只能显示域名的问题。
///
/// 规则 14 的边界仍然成立：系统阅读器（`SFSafariViewController`）继续作为
/// 「打开原文 / 网页版」的逃生口保留；这里的 WebView 是**导入文章的阅读界面**，
/// 不是拿它去替代所有原文链接。
@MainActor
final class ArticleWebModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {

    @Published private(set) var isLoading = false
    @Published private(set) var articleText: String?
    @Published private(set) var pageTitle: String?
    @Published private(set) var errorMessage: String?
    /// 微信风控页（wappoc_appmsgcaptcha）：页面能显示，但正文还没到。
    /// 不能弹错误遮罩 —— 用户需要在这个页面上完成验证，遮住就没法操作了。
    @Published private(set) var requiresVerification = false

    let webView: WKWebView

    private var loadedURL: URL?
    /// 正文上限：够 AI 对话与练习用，又不至于把内存和提示词撑爆。
    private static let maximumTextCharacters = 20_000

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // 阅读器底色跟随 App 主题：页面加载中、回弹、以及正文没铺满的地方
        // 都显示同一个底色，不会出现 WKWebView 默认的白色块。
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.underPageBackgroundColor = UIColor(Theme.background)
    }

    func load(_ url: URL) {
        if loadedURL == url, webView.url != nil { return }
        loadedURL = url
        articleText = nil
        pageTitle = nil
        errorMessage = nil
        isLoading = true
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    func reload() {
        guard let url = loadedURL else { return }
        errorMessage = nil
        isLoading = true
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }

    // MARK: - 导航

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        requiresVerification = webView.url?.absoluteString.contains("wappoc_appmsgcaptcha") == true
        injectReaderStyleIfNeeded()
        extract()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handle(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handle(error)
    }

    /// 正文里的 `target=_blank` 链接：还在这个 WebView 里打开，别让 WebKit 新建一个看不见的窗口。
    /// 自定义协议（`xhsdiscover://` 等）不塞进来 —— 塞进来只会触发下一条的导航策略。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        guard ArticleNavigationPolicy.isInPage(
            scheme: navigationAction.request.url?.scheme
        ) else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    /// 阅读器只放行 http(s)/about/data/blob。
    ///
    /// 其余协议（`xhsdiscover://`、`weixin://`、`tel:` …）**只有用户自己点了链接**
    /// 才交给系统：小红书这类页面一打开就用 JS 往自己的 App scheme 上跳，无条件
    /// `open` 会立刻弹「在『小红书』中打开？」，把用户从阅读器里带走。页面自动
    /// 发起的跳转一律静默取消。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let decision = ArticleNavigationPolicy.decision(
            scheme: url?.scheme,
            isLinkActivated: navigationAction.navigationType == .linkActivated
        )

        switch decision {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally:
            decisionHandler(.cancel)
            if let url {
                UIApplication.shared.open(url)
            }
        }
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        // -999（用户/代码取消了导航）不是错误
        guard ns.code != NSURLErrorCancelled else { return }
        isLoading = false
        errorMessage = "文章没有加载出来：\(error.localizedDescription)"
    }

    // MARK: - 取标题与正文

    private func extract() {
        // 验证页上的文字不是文章正文：不要把它当成正文喂给 AI/练习
        guard !requiresVerification else {
            articleText = nil
            return
        }

        let script = """
        (function(){
          var meta = document.querySelector('meta[property="og:title"]');
          var title = (meta && meta.content) || document.title || '';
          var node = document.querySelector('#js_content')
                  || document.querySelector('article')
                  || document.querySelector('main')
                  || document.body;
          var text = node ? node.innerText : '';
          return JSON.stringify({ title: title, text: text });
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self,
                  let json = result as? String,
                  let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { return }

            if let title = SharedLinkURL.cleanedTitle(object["title"]) {
                self.pageTitle = title
            }

            if let text = object["text"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                self.articleText = String(text.prefix(Self.maximumTextCharacters))
            }
        }
    }

    /// 公众号页面自己的顶栏/底栏/二维码不是文章内容，藏掉；正文容器改为透明，
    /// 让 App 的主题底色统一透出来。
    ///
    /// **不要强制 `body{background:#fff}`**：深色模式下那会在正文上方/下方露出
    /// 一块白底（页面自己的深色文字反而压在白色上），也就是用户看到的「白色区域」。
    /// 只对公众号域名生效 —— 普通站点保持原样（「尽量保持原样式」）。
    private func injectReaderStyleIfNeeded() {
        guard let host = webView.url?.host?.lowercased(),
              SharedLinkURL.isWeChatHost(host) else { return }

        let script = """
        (function(){
          if (document.getElementById('aihot-reader-style')) return;
          var style = document.createElement('style');
          style.id = 'aihot-reader-style';
          style.textContent = [
            '#js_article_bottom_bar,.rich_media_area_extra,.rich_media_tool,#js_pc_qr_code,.qr_code_pc_outer{display:none!important}',
            'html,body,.rich_media,.rich_media_inner,#js_article,.rich_media_area_primary,#js_content{background:transparent!important}',
            'html,body{margin:0!important}',
            '.rich_media_content{max-width:100%!important;padding-left:0!important;padding-right:0!important}'
          ].join('');
          document.head.appendChild(style);
        })()
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}

/// 阅读器遇到一次导航时该怎么办。
///
/// 纯函数放在这里而不是写死在 delegate 里，是为了能单测：小红书页面的自动
/// 跳转（`xhsdiscover://…`）必须静默取消，否则一打开文章就弹「在『小红书』
/// 中打开？」。只有用户真的点了链接（`WKNavigationType.linkActivated`）才
/// 交给系统。
enum ArticleNavigationPolicy {

    enum Decision: Equatable {
        /// 留在 WebView 里继续加载。
        case allow
        /// 静默丢弃：页面自己发起的自定义协议跳转。
        case cancel
        /// 用户主动点了链接：取消 WebView 内的加载，交给系统打开。
        case openExternally
    }

    /// 这些协议在阅读器内部继续加载。
    static let inPageSchemes: Set<String> = ["http", "https", "about", "data", "blob"]

    static func isInPage(scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return true }
        return inPageSchemes.contains(scheme)
    }

    static func decision(scheme: String?, isLinkActivated: Bool) -> Decision {
        if isInPage(scheme: scheme) { return .allow }
        return isLinkActivated ? .openExternally : .cancel
    }
}

/// 把模型持有的 WKWebView 交给 SwiftUI。同一个模型实例始终返回同一个 WebView，
/// 不会在每次刷新时重建页面。
struct ArticleWebView: UIViewRepresentable {

    @ObservedObject var model: ArticleWebModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
