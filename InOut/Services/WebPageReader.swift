import Foundation

/// `read_url` 的执行者：App 自己抓网页正文。
///
/// 元宝搜索只有搜索接口，没有「读网页」接口；所以这一步不经过腾讯云，
/// 直接用 URLSession 取页面、用现成的 `HTMLTextExtractor` 压成纯文本。
/// 链接校验沿用 `SharedLinkURL.normalized`（公开 http/https，安全边界）。
///
/// 微信的公众号文章会落到风控验证页 —— 这种情况明确报错，不要拿验证页
/// 的文字冒充正文（App 内有专门的阅读器，用户可以去那里完成验证）。
struct WebPageReader: AIChatToolExecuting {

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    func execute(call: AIChatToolCall) async -> (text: String, isError: Bool) {
        guard let raw = call.string("url") else {
            return AIChatToolResult.missingArgument(AIChatToolName.readURL)
        }
        guard let url = SharedLinkURL.normalized(raw) else {
            return AIChatToolResult.failure(
                AIChatToolName.readURL,
                "网址无效：只支持公开的 http/https 网页。"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  data.count <= 2_000_000
            else {
                return AIChatToolResult.failure(
                    AIChatToolName.readURL,
                    "页面没有返回可读内容（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。"
                )
            }

            let finalURL = http.url?.absoluteString ?? url.absoluteString
            let html = String(decoding: data, as: UTF8.self)

            if finalURL.contains("wappoc_appmsgcaptcha") || html.contains("请在微信客户端打开") {
                return AIChatToolResult.failure(
                    AIChatToolName.readURL,
                    "微信要求先在页面内完成验证，App 无法直接读取这篇公众号文章。"
                        + "可以打开这篇文章在阅读器里完成验证后再问。"
                )
            }

            let title = LinkTitleParser.parse(html: html) ?? url.host ?? "网页"
            let body = HTMLTextExtractor.plainText(from: html)

            guard AIChatToolResult.clamp(body).count >= 40 else {
                return AIChatToolResult.failure(
                    AIChatToolName.readURL,
                    "页面没有可读正文（可能是需要登录、只靠脚本渲染，或站点拒绝抓取）。"
                )
            }

            let text = "【网页】\(title)\nURL: \(finalURL)\n\n\(body)"
            return (AIChatToolResult.clamp(text), false)

        } catch let error as URLError {
            return AIChatToolResult.failure(
                AIChatToolName.readURL,
                friendlyMessage(for: error)
            )
        } catch {
            return AIChatToolResult.failure(
                AIChatToolName.readURL,
                "读取失败：\(error.localizedDescription)"
            )
        }
    }

    private func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "网络不可用，稍后再试。"
        case .timedOut:
            return "页面加载超时，稍后再试。"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "连不上这个网站（域名或网络异常）。"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "网站证书有问题，App 不会继续读取。"
        case .appTransportSecurityRequiresSecureConnection:
            return "这个链接是 http，App 的 ATS 不允许读取；请换 https 链接。"
        default:
            return "读取失败：\(error.localizedDescription)"
        }
    }
}
