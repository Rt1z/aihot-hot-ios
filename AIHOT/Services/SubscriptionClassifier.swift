import Foundation

/// 订阅内容的本地分类器。
///
/// **纯函数、无网络、无日期、无随机**：同一条标题在任何时候、任何设备上都得到同一个板块。
/// 这也是 `tools/logic_tests.py` 镜像 21 能钉住它的前提。
///
/// 三条容易被「优化」坏掉的规则：
/// 1. 中文关键词按子串匹配；纯 ASCII 关键词（AI / GPU / OpenAI）必须按词边界匹配，
///    否则 `ai` 会命中 `again`、`email`、`said`。
/// 2. 标题命中权重 3、摘要命中权重 1，每个关键词在每个字段里最多算一次 ——
///    一个词重复十遍不代表这篇文章更「科技」。
/// 3. 平分按 `SubscriptionTopic.allCases` 的顺序（科技 → 健康 → 成长 → 职业 → 周边），
///    **不要遍历字典**：Swift 与 Python 的字典顺序都不稳定。
///
/// 词库刻意保持「宁可少分，不可错分」：宁可不命中落到周边，也不要把健康文章塞进科技。
enum SubscriptionClassifier {

    /// 词库。Swift 这份是权威；`tools/logic_tests.py` 里有一份逐字镜像，
    /// 改一边必须改另一边（规则 4）。每个关键词只能属于一个板块。
    static let lexicon: [(keyword: String, topic: SubscriptionTopic)] = [
        // 科技
        ("ai", .tech),
        ("人工智能", .tech),
        ("大模型", .tech),
        ("大语言模型", .tech),
        ("模型", .tech),
        ("算法", .tech),
        ("芯片", .tech),
        ("半导体", .tech),
        ("算力", .tech),
        ("开源", .tech),
        ("编程", .tech),
        ("程序员", .tech),
        ("代码", .tech),
        ("软件", .tech),
        ("硬件", .tech),
        ("手机", .tech),
        ("电脑", .tech),
        ("苹果", .tech),
        ("华为", .tech),
        ("小米", .tech),
        ("机器人", .tech),
        ("自动驾驶", .tech),
        ("互联网", .tech),
        ("数据", .tech),
        ("网络安全", .tech),
        ("量子", .tech),
        ("卫星", .tech),
        ("火箭", .tech),
        ("新能源", .tech),
        ("电池", .tech),
        ("光伏", .tech),
        ("储能", .tech),
        ("openai", .tech),
        ("chatgpt", .tech),
        ("claude", .tech),
        ("deepseek", .tech),
        ("gpu", .tech),
        ("云计算", .tech),

        // 健康
        ("健康", .health),
        ("医疗", .health),
        ("医院", .health),
        ("医生", .health),
        ("疾病", .health),
        ("癌症", .health),
        ("疫苗", .health),
        ("药物", .health),
        ("睡眠", .health),
        ("饮食", .health),
        ("营养", .health),
        ("减肥", .health),
        ("运动", .health),
        ("健身", .health),
        ("心理", .health),
        ("焦虑", .health),
        ("抑郁", .health),
        ("血糖", .health),
        ("血压", .health),
        ("心脏", .health),
        ("养生", .health),
        ("体检", .health),
        ("免疫力", .health),
        ("肠道", .health),
        ("衰老", .health),

        // 成长
        ("读书", .growth),
        ("阅读", .growth),
        ("学习", .growth),
        ("认知", .growth),
        ("思维", .growth),
        ("思考", .growth),
        ("成长", .growth),
        ("习惯", .growth),
        ("自律", .growth),
        ("复盘", .growth),
        ("效率", .growth),
        ("方法论", .growth),
        ("知识", .growth),
        ("教育", .growth),
        ("笔记", .growth),
        ("写作", .growth),
        ("专注", .growth),
        ("时间管理", .growth),
        ("情绪", .growth),
        ("自我提升", .growth),
        ("终身学习", .growth),

        // 职业
        ("职场", .career),
        ("面试", .career),
        ("简历", .career),
        ("招聘", .career),
        ("晋升", .career),
        ("跳槽", .career),
        ("管理", .career),
        ("领导力", .career),
        ("团队", .career),
        ("沟通", .career),
        ("汇报", .career),
        ("绩效", .career),
        ("副业", .career),
        ("创业", .career),
        ("裁员", .career),
        ("薪资", .career),
        ("薪酬", .career),
        ("职业", .career),
        ("求职", .career),
        ("同事", .career),
        ("老板", .career),

        // 周边（也是「什么都没命中」的兜底）
        ("数码", .peripheral),
        ("耳机", .peripheral),
        ("相机", .peripheral),
        ("键盘", .peripheral),
        ("显示器", .peripheral),
        ("鼠标", .peripheral),
        ("音箱", .peripheral),
        ("智能家居", .peripheral),
        ("汽车", .peripheral),
        ("咖啡", .peripheral),
        ("旅行", .peripheral),
        ("美食", .peripheral),
        ("摄影", .peripheral),
        ("游戏", .peripheral),
        ("电影", .peripheral),
        ("音乐", .peripheral),
        ("穿搭", .peripheral),
        ("好物", .peripheral),
        ("测评", .peripheral),
        ("桌搭", .peripheral),
        ("露营", .peripheral),
        ("骑行", .peripheral)
    ]

    /// 标题里一个关键词算 3 分，摘要里算 1 分。
    static let titleWeight = 3
    static let summaryWeight = 1

    static func classify(title: String, summary: String) -> SubscriptionTopic {
        let scores = self.scores(title: title, summary: summary)
        var best: SubscriptionTopic = .peripheral
        var bestScore = 0
        for topic in SubscriptionTopic.allCases {
            let score = scores[topic] ?? 0
            // 严格大于：平分时保留 allCases 里更靠前的那个。
            if score > bestScore {
                best = topic
                bestScore = score
            }
        }
        return bestScore == 0 ? .peripheral : best
    }

    static func scores(title: String, summary: String) -> [SubscriptionTopic: Int] {
        let normalizedTitle = normalize(title)
        let normalizedSummary = normalize(summary)

        var scores: [SubscriptionTopic: Int] = [:]
        for topic in SubscriptionTopic.allCases {
            scores[topic] = 0
        }

        for entry in lexicon {
            let keyword = normalize(entry.keyword)
            guard !keyword.isEmpty else { continue }
            var score = 0
            if contains(keyword: keyword, in: normalizedTitle) {
                score += titleWeight
            }
            if contains(keyword: keyword, in: normalizedSummary) {
                score += summaryWeight
            }
            if score > 0 {
                scores[entry.topic, default: 0] += score
            }
        }
        return scores
    }

    // MARK: - 归一化

    /// 全角 ASCII → 半角、全角空格 → 空格、连续空白折叠、
    /// **只把 ASCII A–Z 转小写**（不碰中文，不用 locale 相关 API）。
    static func normalize(_ raw: String) -> String {
        var scalars: [Unicode.Scalar] = []
        var lastWasSpace = false

        for scalar in raw.unicodeScalars {
            var value = scalar
            if value.value >= 0xFF01 && value.value <= 0xFF5E {
                value = Unicode.Scalar(value.value - 0xFEE0) ?? value
            } else if value.value == 0x3000 {
                value = " "
            }

            if value == " " || value == "\t" || value == "\n" || value == "\r" {
                if !lastWasSpace {
                    scalars.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            lastWasSpace = false

            if value.value >= 0x41 && value.value <= 0x5A {
                value = Unicode.Scalar(value.value + 0x20) ?? value
            }
            scalars.append(value)
        }

        var text = String(String.UnicodeScalarView(scalars))
        while text.hasPrefix(" ") { text.removeFirst() }
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    // MARK: - 匹配

    /// 纯 ASCII 关键词走词边界；含中文的走子串。
    static func contains(keyword: String, in haystack: String) -> Bool {
        guard !keyword.isEmpty, !haystack.isEmpty else { return false }
        guard isASCIIWord(keyword) else {
            return haystack.contains(keyword)
        }
        return containsWithASCIIBoundary(keyword, in: haystack)
    }

    /// 关键词全部由 ASCII 字母/数字/常见连接符组成时，才需要词边界。
    /// 含中文、全角符号的关键词直接子串匹配。
    static func isASCIIWord(_ keyword: String) -> Bool {
        var hasLetterOrDigit = false
        for scalar in keyword.unicodeScalars {
            let value = scalar.value
            let letter = (value >= 0x61 && value <= 0x7A) || (value >= 0x41 && value <= 0x5A)
            let digit = value >= 0x30 && value <= 0x39
            if letter || digit {
                hasLetterOrDigit = true
                continue
            }
            // 词内的空格、连字符、点、加号允许（GPT-5、time management）。
            if value == 0x20 || value == 0x2D || value == 0x2E || value == 0x2B || value == 0x5F {
                continue
            }
            return false
        }
        return hasLetterOrDigit
    }

    private static func containsWithASCIIBoundary(_ keyword: String, in haystack: String) -> Bool {
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: keyword, range: searchStart..<haystack.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == haystack.startIndex {
                beforeOK = true
            } else {
                let previous = haystack[haystack.index(before: range.lowerBound)]
                beforeOK = !isASCIIAlphanumeric(previous)
            }
            let afterOK: Bool
            if range.upperBound == haystack.endIndex {
                afterOK = true
            } else {
                let next = haystack[range.upperBound]
                afterOK = !isASCIIAlphanumeric(next)
            }
            if beforeOK && afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        let value = scalar.value
        return (value >= 0x30 && value <= 0x39)
            || (value >= 0x41 && value <= 0x5A)
            || (value >= 0x61 && value <= 0x7A)
    }
}
