import Foundation

/// 模型榜页面 HTML 的纯解析器（无网络、无状态）。
///
/// 榜单没有公开 JSON 接口，数据只存在于 SSR HTML 里。解析全部锚定**可见文案**
/// 与稳定属性（`data-slug`、`aria-label`、`href`），不依赖 Tailwind class 名 ——
/// 与 `HotPageEnricher` 同一信条：宁可少抽，不可抽错。
/// 任何认不出来的页面返回 nil，上层静默降级（缓存或横幅）。
///
/// 与 `tools/logic_tests.py` 的镜像 17 读同一批夹具；夹具是真实抓取，
/// 分数会随站点更新漂移 —— 测试钉的是**解析器对这份字节的行为**。
enum LeaderboardParser {

    // MARK: - 榜页（综合/分类同构）

    static func parseBoard(html: String, category: LeaderboardCategory) -> LeaderboardBoard? {
        let main = mainSection(of: html)
        let text = HTMLTextExtractor.plainText(from: main)

        let rowResults = RegexUtil.matches(
            #"<tr data-slug="([^"]+)"[^>]*>(.*?)</tr>"#,
            in: main,
            options: [.dotMatchesLineSeparators]
        )
        var models: [LeaderboardModel] = []
        for row in rowResults {
            guard let slug = RegexUtil.group(row, at: 1, in: main),
                  let body = RegexUtil.group(row, at: 2, in: main),
                  let model = parseRow(slug: slug, html: body) else { continue }
            models.append(model)
        }
        // 一行都认不出 = 页面改版了，别拿半份数据出去
        guard !models.isEmpty else { return nil }

        // 页头：「35 项评测 · 7 家机构 · 10/20 09:12 更新」
        var evalTotal: Int?
        var institutionCount: Int?
        var updatedText: String?
        if let header = RegexUtil.firstMatch(
            #"(\d+) 项评测 · (\d+) 家机构 · (\d{1,2}/\d{1,2} \d{2}:\d{2}) 更新"#,
            in: text
        ) {
            evalTotal = RegexUtil.group(header, at: 1, in: text).flatMap(Int.init)
            institutionCount = RegexUtil.group(header, at: 2, in: text).flatMap(Int.init)
            updatedText = RegexUtil.group(header, at: 3, in: text)
        }

        return LeaderboardBoard(
            category: category,
            updatedText: updatedText,
            evalTotal: evalTotal,
            institutionCount: institutionCount,
            models: models
        )
    }

    /// 一行 `<tr>` → 模型。行内先压成「一行一格」（plainText 的块级标签表含 /td|/tr）：
    /// ```
    /// 01 · Claude Opus 5.5 Anthropic · 2026-09-22 · 34 项评测 覆盖 96 % · ¥1.34 · ¥26.72 · ¥133.61 · 73.8 覆盖 96 %
    /// ```
    private static func parseRow(slug: String, html: String) -> LeaderboardModel? {
        // 模型名取行内第一个 <a> 的可见文本（格里还有厂商名等噪音，锚 <a> 最干净）
        let name: String
        if let link = RegexUtil.firstMatch(#"<a[^>]*>(.*?)</a>"#, in: html, options: [.dotMatchesLineSeparators]),
           let raw = RegexUtil.group(link, at: 1, in: html) {
            name = collapseSpaces(HTMLTextExtractor.normalize(HTMLTextExtractor.plainText(from: raw)))
        } else {
            return nil
        }

        let text = HTMLTextExtractor.plainText(from: html)
        let lines = text.components(separatedBy: "\n")

        // 第一格 = 两位名次
        guard let first = lines.first,
              let rank = Int(first.trimmingCharacters(in: .whitespaces)),
              (1...99).contains(rank) else { return nil }

        var releasedISO: String?
        var evalCount: Int?
        var coveragePercent: Int?
        var prices: [String] = []
        var score: Double?

        // Swift 的 ^/$ 默认锚整个字符串，不是按行 —— 行内锚点必须带 .anchorsMatchLines
        let lineAnchored: NSRegularExpression.Options = [.anchorsMatchLines]
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            if releasedISO == nil,
               RegexUtil.firstMatch(#"^\d{4}-\d{2}-\d{2}$"#, in: value, options: lineAnchored) != nil {
                releasedISO = value
            }
            if evalCount == nil,
               let match = RegexUtil.firstMatch(#"(\d+) 项评测"#, in: value) {
                evalCount = RegexUtil.group(match, at: 1, in: value).flatMap(Int.init)
            }
            if coveragePercent == nil,
               let match = RegexUtil.firstMatch(#"覆盖 (\d+) ?%"#, in: value) {
                coveragePercent = RegexUtil.group(match, at: 1, in: value).flatMap(Int.init)
            }
            if value.hasPrefix("¥") && prices.count < 3 {
                prices.append(value)
            }
            // 评分格：「73.8  覆盖 96 %」——开头是裸小数
            if score == nil,
               let match = RegexUtil.firstMatch(#"^([\d.]+)  ?覆盖"#, in: value, options: lineAnchored) {
                score = RegexUtil.group(match, at: 1, in: value).flatMap(Double.init)
            }
        }

        // 厂商 = 模型名那一格里、名字后面第一段（"Claude Opus 5.5    Anthropic  Anthropic · …"）。
        // 只用可见文本切分，不碰 <small>/<strong> 的 class 名。
        var provider: String?
        if lines.count > 1 {
            let parts = lines[1].components(separatedBy: "  ").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            if parts.first == name, parts.count > 1 {
                provider = parts[1]
            }
        }

        return LeaderboardModel(
            rank: rank,
            slug: slug,
            name: name,
            provider: provider,
            releasedISO: releasedISO,
            evalCount: evalCount,
            coveragePercent: coveragePercent,
            cachePrice: prices.count > 0 ? prices[0] : nil,
            inputPrice: prices.count > 1 ? prices[1] : nil,
            outputPrice: prices.count > 2 ? prices[2] : nil,
            score: score
        )
    }

    // MARK: - 详情页

    static func parseDetail(html: String) -> LeaderboardDetail? {
        let main = mainSection(of: html)
        let text = HTMLTextExtractor.plainText(from: main)

        // <h1 data-page-title> 是最稳的名字锚
        guard let title = RegexUtil.firstMatch(
                #"<h1[^>]*>(.*?)</h1>"#, in: main, options: [.dotMatchesLineSeparators]),
              let name = RegexUtil.group(title, at: 1, in: main).map({ HTMLTextExtractor.normalize(HTMLTextExtractor.plainText(from: $0)) }),
              !name.isEmpty
        else { return nil }

        var provider: String?
        var releasedText: String?
        var updatedText: String?
        var overallScore: Double?
        var overallRank: Int?
        var coveragePercent: Int?
        var contextWindowText: String?
        var inputPrice: String?
        var outputPrice: String?
        var cachePrice: String?
        var originalUSDText: String?

        // 「Anthropic · 2026-09-22 发布 · 10/20 09:12 更新」（^/$ 按行锚；
        // [^\n·] 不能写成 [^·] —— 字符类默认吃换行，会把上面几行一起卷进厂商名）
        if let meta = RegexUtil.firstMatch(
            #"^([^\n·]+) · (\d{4}-\d{2}-\d{2}) 发布 · (\d{1,2}/\d{1,2} \d{2}:\d{2}) 更新$"#,
            in: text,
            options: [.anchorsMatchLines]
        ) {
            provider = RegexUtil.group(meta, at: 1, in: text)?.trimmingCharacters(in: .whitespaces)
            releasedText = RegexUtil.group(meta, at: 2, in: text).map { "\($0) 发布" }
            updatedText = RegexUtil.group(meta, at: 3, in: text)
        }

        // 「AIHOT 评分 · 综合  73.8 分   综合第 1 名  评分不是正确率 · 评测覆盖 96 %」
        if let score = RegexUtil.firstMatch(
            #"AIHOT 评分 · 综合\s+([\d.]+) 分\s+综合第 (\d+) 名[^\d]*评测覆盖 (\d+) ?%"#, in: text
        ) {
            overallScore = RegexUtil.group(score, at: 1, in: text).flatMap(Double.init)
            overallRank = RegexUtil.group(score, at: 2, in: text).flatMap(Int.init)
            coveragePercent = RegexUtil.group(score, at: 3, in: text).flatMap(Int.init)
        }

        // 概览四格
        if let ctx = RegexUtil.firstMatch(#"上下文窗口\s+(\S+ Token)"#, in: text) {
            contextWindowText = RegexUtil.group(ctx, at: 1, in: text)
        }
        if let price = RegexUtil.firstMatch(
            #"API 输入 / 输出 · 每百万 Token\s+(¥\S+) / (\S+)\s+缓存 (¥\S+)[^$]*原价 (.+?) 厂商官方价格"#,
            in: text
        ) {
            inputPrice = RegexUtil.group(price, at: 1, in: text)
            outputPrice = RegexUtil.group(price, at: 2, in: text)
            cachePrice = RegexUtil.group(price, at: 3, in: text)
            // 非贪婪 .+? 停在「厂商官方价格」前一格，可能带尾随空格 —— 展示前削掉
            originalUSDText = RegexUtil.group(price, at: 4, in: text)?
                .trimmingCharacters(in: .whitespaces)
        }

        let cards = parseCategoryCards(html: main)
        let groups = parseBenchmarkGroups(html: main)

        return LeaderboardDetail(
            name: name,
            provider: provider,
            releasedText: releasedText,
            updatedText: updatedText,
            overallScore: overallScore,
            overallRank: overallRank,
            coveragePercent: coveragePercent,
            contextWindowText: contextWindowText,
            inputPrice: inputPrice,
            outputPrice: outputPrice,
            cachePrice: cachePrice,
            originalUSDText: originalUSDText,
            cards: cards,
            groups: groups
        )
    }

    /// CAPABILITY PROFILE 四卡：`<a href="/leaderboard/category/…">` 里带「AIHOT 评分」的才要
    /// （顶部 tab 导航也链到同样的路径，但那里没有评分文案 —— 以此区分，宁可少抽）。
    private static func parseCategoryCards(html: String) -> [LeaderboardDetail.CategoryCard] {
        let anchors = RegexUtil.matches(
            #"<a[^>]*href="/leaderboard/category/(\w+)"[^>]*>(.*?)</a>"#,
            in: html,
            options: [.dotMatchesLineSeparators]
        )
        var cards: [LeaderboardDetail.CategoryCard] = []
        for anchor in anchors {
            guard let raw = RegexUtil.group(anchor, at: 2, in: html) else { continue }
            let body = HTMLTextExtractor.plainText(from: raw)
            guard body.contains("AIHOT 评分"),
                  let slug = RegexUtil.group(anchor, at: 1, in: html),
                  let category = LeaderboardCategory(rawValue: slug),
                  let match = RegexUtil.firstMatch(
                    #"AIHOT 评分\s+([\d.]+) 分\s+第 (\d+) 名\s+(\d+) 项评测 · 覆盖 (\d+) ?%"#,
                    in: body
                  )
            else { continue }
            cards.append(LeaderboardDetail.CategoryCard(
                category: category,
                score: RegexUtil.group(match, at: 1, in: body).flatMap(Double.init),
                rank: RegexUtil.group(match, at: 2, in: body).flatMap(Int.init),
                evalCount: RegexUtil.group(match, at: 3, in: body).flatMap(Int.init),
                coveragePercent: RegexUtil.group(match, at: 4, in: body).flatMap(Int.init)
            ))
        }
        return cards
    }

    /// BEHIND THE SCORE：从标记处开始，`<h3>` 开一组、`<li class="card …">` 逐项。
    /// 每个 li 单独压文本再按「折算分」切 —— 整页统一切行会被字母徽章（如 P）
    /// 在名字里劈出双空格，逐块切没有这个问题。
    private static func parseBenchmarkGroups(html: String) -> [LeaderboardDetail.BenchmarkGroup] {
        guard let markerRange = html.range(of: "BEHIND THE SCORE") else { return [] }
        let section = String(html[markerRange.lowerBound...])

        let tokens = RegexUtil.matches(
            #"(<h3[^>]*>.*?</h3>)|(<li class="card[^"]*"[^>]*>.*?</li>)"#,
            in: section,
            options: [.dotMatchesLineSeparators]
        )

        var groups: [LeaderboardDetail.BenchmarkGroup] = []
        var currentHeading: String?
        var currentCategory: LeaderboardCategory?
        var currentScore: Double?
        var currentCount: Int?
        var currentItems: [LeaderboardDetail.Benchmark] = []

        func flush() {
            guard let heading = currentHeading else { return }
            groups.append(LeaderboardDetail.BenchmarkGroup(
                heading: heading,
                category: currentCategory,
                score: currentScore,
                evalCount: currentCount,
                items: currentItems
            ))
            currentHeading = nil
            currentCategory = nil
            currentScore = nil
            currentCount = nil
            currentItems = []
        }

        for token in tokens {
            let raw = token.range(at: 1).location != NSNotFound
                ? RegexUtil.group(token, at: 1, in: section)
                : RegexUtil.group(token, at: 2, in: section)
            guard let raw = raw else { continue }

            if token.range(at: 1).location != NSNotFound {
                // <h3>编程 74.3 8 项</h3> 开一组
                let headingText = HTMLTextExtractor.normalize(HTMLTextExtractor.plainText(from: raw))
                guard let match = RegexUtil.firstMatch(
                    #"^(编程|科研|专业办公|知识问答|真人盲选) ([\d.]+) ?(\d+) 项$"#, in: headingText
                ) else { continue }
                flush()
                currentHeading = RegexUtil.group(match, at: 1, in: headingText)
                currentScore = RegexUtil.group(match, at: 2, in: headingText).flatMap(Double.init)
                currentCount = RegexUtil.group(match, at: 3, in: headingText).flatMap(Int.init)
                currentCategory = currentHeading.flatMap(LeaderboardCategory.from(heading:))
            } else {
                guard currentHeading != nil else { continue }
                // 字段级锚点提取，不盲切文本 —— 名字前面可能有字母徽章
                // （如 P），盲切会把徽章当成名字。class 名做锚点有改版风险，
                // 由夹具钉住；认不出的行跳过（宁可少抽）。
                guard let nameMatch = RegexUtil.firstMatch(
                        #"text-\[13\.5px\] font-semibold text-ink">([^<]+)</span>"#,
                        in: raw
                      ),
                      let benchmarkName = RegexUtil.group(nameMatch, at: 1, in: raw)
                        .map({ collapseSpaces(HTMLTextExtractor.normalize(HTMLTextExtractor.plainText(from: $0))) }),
                      !benchmarkName.isEmpty
                else { continue }

                var source: String?
                if let sourceMatch = RegexUtil.firstMatch(
                    #"<small class="text-\[11px\] text-ink-4">(.*?)</small>"#,
                    in: raw,
                    options: [.dotMatchesLineSeparators]
                ), let rawSource = RegexUtil.group(sourceMatch, at: 1, in: raw) {
                    let value = collapseSpaces(HTMLTextExtractor.normalize(HTMLTextExtractor.plainText(from: rawSource)))
                    if !value.isEmpty { source = value }
                }

                var scoreText: String?
                if let scoreMatch = RegexUtil.firstMatch(
                    #"mono block text-\[19px\] font-medium leading-tight text-ink">([^<]+)</span>"#,
                    in: raw
                ), let rawScore = RegexUtil.group(scoreMatch, at: 1, in: raw) {
                    let value = rawScore.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { scoreText = value }
                }

                var converted: String?
                if let convertedMatch = RegexUtil.firstMatch(
                    #"折算分(.*?)</span></span>"#,
                    in: raw,
                    options: [.dotMatchesLineSeparators]
                ), let rawConverted = RegexUtil.group(convertedMatch, at: 1, in: raw) {
                    // 「折算分 <!-- -->至多 <span class="num">55.1</span></span>」→ 至多 55.1
                    let value = collapseSpaces(
                        HTMLTextExtractor.normalize(HTMLTextExtractor.plainText(from: rawConverted))
                    )
                    if !value.isEmpty { converted = value }
                }

                currentItems.append(LeaderboardDetail.Benchmark(
                    name: benchmarkName,
                    source: source,
                    scoreText: scoreText,
                    converted: converted
                ))
            }
        }
        flush()
        return groups
    }

    // MARK: - 公共

    /// 只取 `<main>` 里的内容，避开 head/turbo-stream 脚本噪音。
    private static func mainSection(of html: String) -> String {
        if let match = RegexUtil.firstMatch(
            #"<main[^>]*>(.*?)</main>"#, in: html, options: [.dotMatchesLineSeparators]
        ), let body = RegexUtil.group(match, at: 1, in: html) {
            return body
        }
        return html
    }

    /// 连续空白折叠成一个空格（"至多  55.1" → "至多 55.1"）。
    private static func collapseSpaces(_ text: String) -> String {
        RegexUtil.replace(#"\s+"#, in: text, with: " ")
    }
}
