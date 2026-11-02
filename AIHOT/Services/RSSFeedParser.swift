import Foundation

struct ParsedFeed: Equatable {
    /// feed 里 `<channel><title>` 的原文；配置里的 name 优先，这里只作回填。
    let sourceName: String
    let items: [SubscriptionItem]
}

/// RSS 2.0 解析器（RSSHub 的 B 站路由都输出 RSS 2.0）。
///
/// 用系统的 `XMLParser`，不引入依赖。读的是**字节**：先看开头是不是 `<rss` / `<?xml`，
/// 因为 RSSHub 出错时经常返回 HTTP 200 的 HTML 错误页或 JSON，交给 XMLParser 只会得到
/// 一句看不懂的解析失败。`description` 里的 HTML 交给 `SubscriptionHTML`。
final class RSSFeedParser: NSObject, XMLParserDelegate {

    private struct ItemBuffer {
        var title = ""
        var link = ""
        var description = ""
        var contentEncoded = ""
        var pubDate = ""
        var guid = ""
        var author = ""
        var mediaCover: String?
    }

    private var channelTitle = ""
    private var currentItem: ItemBuffer?
    private var currentElement: String?
    private var buffer = ""
    private var sawRSSRoot = false
    private var items: [ItemBuffer] = []
    private var parseError: Error?

    static func parse(
        data: Data,
        source: SubscriptionSource,
        defaultName: String = "B 站"
    ) throws -> ParsedFeed {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let lower = trimmed.lowercased()

        guard !trimmed.isEmpty else {
            throw SubscriptionError(kind: .invalidFeed, message: "RSSHub 返回了空内容")
        }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.hasPrefix("{") || lower.hasPrefix("[") {
            throw SubscriptionError(
                kind: .invalidFeed,
                message: "RSSHub 返回的不是 RSS（路由写错、访问码不对，或实例报错）"
            )
        }
        // XML 声明可能挡在 <feed> 前面，先把声明剥掉再判断根元素。
        let withoutDeclaration = lower.replacingOccurrences(
            of: #"^<\?xml[^>]*\?>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutDeclaration.hasPrefix("<feed") {
            throw SubscriptionError(
                kind: .invalidFeed,
                message: "RSSHub 返回的是 Atom，当前只支持 RSS 路由"
            )
        }
        guard lower.hasPrefix("<?xml") || lower.hasPrefix("<rss") else {
            throw SubscriptionError(
                kind: .invalidFeed,
                message: "RSSHub 返回的不是 RSS（开头不是 <rss>）"
            )
        }

        // 当前 SDK 的 `XMLParser(data:)` 是非可选的；不要写 `guard let`。
        let parser = XMLParser(data: data)
        let delegate = RSSFeedParser()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        let ok = parser.parse()
        if !ok {
            let line = parser.lineNumber
            let detail = delegate.parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "未知原因"
            throw SubscriptionError(
                kind: .invalidFeed,
                message: "RSS 解析失败（第 \(line) 行）：\(detail)"
            )
        }
        guard delegate.sawRSSRoot else {
            throw SubscriptionError(kind: .invalidFeed, message: "RSSHub 返回的不是 RSS 2.0")
        }

        let sourceName = source.name.isEmpty
            ? (delegate.channelTitle.isEmpty ? defaultName : delegate.channelTitle)
            : source.name

        var seen = Set<String>()
        var result: [SubscriptionItem] = []
        for raw in delegate.items {
            let title = SubscriptionHTML.cleanTitle(raw.title)
            guard !title.isEmpty else { continue }
            let link = raw.link.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = raw.description.isEmpty ? raw.contentEncoded : raw.description
            let publishedAt = SubscriptionDate.parseRSS(raw.pubDate)
            let id = SubscriptionItemID.make(
                kind: .bilibili,
                sourceID: source.id,
                rawID: raw.guid.isEmpty ? link : raw.guid,
                link: link,
                title: title,
                publishedAt: publishedAt
            )
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            let mediaCover = raw.mediaCover.flatMap {
                SubscriptionHTML.normalizeCoverURL($0, baseURL: link)
            }
            let cover = mediaCover ?? SubscriptionHTML.coverURL(from: description, baseURL: link)

            result.append(
                SubscriptionItem(
                    id: id,
                    sourceID: source.id,
                    sourceName: sourceName,
                    kind: .bilibili,
                    title: title,
                    summary: SubscriptionHTML.summary(from: description),
                    link: link,
                    coverURL: cover,
                    publishedAt: publishedAt
                )
            )
        }

        return ParsedFeed(sourceName: sourceName, items: result)
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = elementName.lowercased()
        if element == "rss" { sawRSSRoot = true }

        if element == "item" {
            currentItem = ItemBuffer()
        }

        if currentItem != nil {
            switch element {
            case "media:content", "media:thumbnail":
                if let url = attributeDict["url"] ?? attributeDict["href"], !url.isEmpty {
                    currentItem?.mediaCover = url
                }
            case "enclosure":
                let type = (attributeDict["type"] ?? "").lowercased()
                if type.hasPrefix("image/"),
                   let url = attributeDict["url"],
                   !url.isEmpty {
                    currentItem?.mediaCover = url
                }
            default:
                break
            }
        }

        currentElement = element
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            buffer += text
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let text = buffer

        if currentItem != nil {
            switch element {
            case "title": currentItem?.title = text
            case "link": currentItem?.link = text
            case "description": currentItem?.description = text
            case "content:encoded": currentItem?.contentEncoded = text
            case "pubdate": currentItem?.pubDate = text
            case "guid": currentItem?.guid = text
            case "author": if currentItem?.author.isEmpty == true { currentItem?.author = text }
            case "dc:creator": if currentItem?.author.isEmpty == true { currentItem?.author = text }
            case "item":
                if let item = currentItem { items.append(item) }
                currentItem = nil
            default:
                break
            }
        } else if element == "title", channelTitle.isEmpty {
            channelTitle = text
        }

        currentElement = nil
        buffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}
