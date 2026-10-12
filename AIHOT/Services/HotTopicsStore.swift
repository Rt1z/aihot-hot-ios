import Combine
import Foundation

/// 热点榜的数据中枢：拉取、节流、ETag、快照、摘要补全、网页增强。
@MainActor
final class HotTopicsStore: ObservableObject {

    struct Notice: Equatable {
        enum Kind: Equatable {
            case offline
            case rateLimited
            case failed
        }
        let kind: Kind
        let message: String
    }

    @Published private(set) var items: [HotTopic] = []
    @Published private(set) var enrichment: HotPageEnrichment?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var notice: Notice?
    @Published private(set) var hasLoaded = false

    /// publicId -> digest，给榜单大卡显示和官网一致的正文段落。
    @Published private(set) var digests: [String: String] = [:]

    /// 最近一次从 /hot 页面提取出来的纯文本，只用于「复制诊断信息」。
    @Published private(set) var lastPageText: String?

    private let api: AIHOTAPI

    /// 官方约定：共享缓存 60s，刷新不要比这更快。
    private let minimumRefreshInterval: TimeInterval = 60
    /// 摘要不是每次刷新都必须重取。
    private let minimumDigestInterval: TimeInterval = 300
    /// /hot 是一整页 HTML，比 JSON 重得多，拉得比榜单更稀一些。
    private let minimumEnrichmentInterval: TimeInterval = 180

    private var lastAttemptAt: Date = .distantPast
    private var lastDigestFetchAt: Date = .distantPast
    private var lastEnrichmentAt: Date = .distantPast
    /// 服务端要求我们等到这个时间点之后（429/503 的 Retry-After）
    private var nextAllowedAt: Date = .distantPast

    init(api: AIHOTAPI = .shared) {
        self.api = api
        if let snapshot = SnapshotCache.load() {
            items = snapshot.response.items.sorted { $0.rank < $1.rank }
            lastUpdated = snapshot.savedAt
            hasLoaded = true
        }
    }

    // MARK: - 派生数据

    var topItems: [HotTopic] { items.filter { $0.rank <= 3 } }
    var restItems: [HotTopic] { items.filter { $0.rank > 3 } }

    func digest(for item: HotTopic) -> String? {
        guard let id = StoryID.publicId(fromStoryLink: item.links?.story) else { return nil }
        return digests[id]
    }

    func enrichmentInfo(for item: HotTopic) -> HotPageEnrichment.RankInfo? {
        enrichment?.info(for: item.rank)
    }

    var lastUpdatedText: String {
        if let updated = enrichment?.updatedText {
            return "\(updated) 更新"
        }
        if let date = lastUpdated {
            return "刷新于 \(RelativeTime.absoluteShort(date))"
        }
        return "尚未更新"
    }

    // MARK: - 拉取

    func loadIfNeeded() async {
        await refresh()
    }

    /// 刷新榜单。
    ///
    /// 没有「强制」开关：节流是**无条件**的（官方要求 poll 不快于 s-maxage），
    /// 只有本地完全没有数据时才放宽到 5 秒，保证首屏能起来、重试有反馈。
    func refresh() async {
        guard !isRefreshing else { return }

        let floor: TimeInterval = items.isEmpty ? 5 : minimumRefreshInterval
        if Date().timeIntervalSince(lastAttemptAt) < floor {
            return
        }

        // 服务端明确让我们等（429/503 的 Retry-After），就别再打过去；
        // 但要把「还要等多久」说出来，否则下拉看上去像没反应。
        if Date() < nextAllowedAt {
            let remaining = Int(nextAllowedAt.timeIntervalSinceNow.rounded(.up))
            if remaining > 0 {
                notice = Notice(kind: .rateLimited, message: "请求过于频繁，\(remaining) 秒后再试")
            }
            return
        }

        isRefreshing = true
        lastAttemptAt = Date()
        defer {
            isRefreshing = false
            hasLoaded = true
        }

        await performFetch()
    }

    private func performFetch() async {
        do {
            let outcome = try await api.hotTopics()
            switch outcome {
            case .modified(let response):
                await applyRanking(response)

            case .notModified:
                if items.isEmpty {
                    // 本地没有榜单却收到 304：ETag 在 UserDefaults 里跨启动保留，
                    // 而快照存在 Caches 里会被系统清掉。此时如果还发条件请求，
                    // 就会一直 304、界面永远停在空态。这次绕开 ETag 重新拉一份。
                    await performFetchIgnoringETag()
                    return
                }
                lastUpdated = Date()
                notice = nil
                await refreshDigests(force: false)
                // 榜单没变，但热度指数/涨跌一直在动，所以这两条路都补一次
                await refreshEnrichment()
            }
        } catch let error as APIError {
            apply(error)
        } catch {
            notice = Notice(kind: .failed, message: "未知错误：\(error.localizedDescription)")
        }
    }

    private func performFetchIgnoringETag() async {
        do {
            let outcome = try await api.hotTopics(ignoreCache: true)
            if case .modified(let response) = outcome {
                await applyRanking(response)
            } else {
                // 绕过缓存还是 304（不该发生），至少给个能看懂的提示
                notice = Notice(kind: .failed, message: "榜单暂时取不到，请稍后下拉重试")
            }
        } catch let error as APIError {
            apply(error)
        } catch {
            notice = Notice(kind: .failed, message: "未知错误：\(error.localizedDescription)")
        }
    }

    private func applyRanking(_ response: HotTopicsResponse) async {
        items = response.items.sorted { $0.rank < $1.rank }
        lastUpdated = Date()
        notice = nil
        SnapshotCache.save(response)
        await refreshDigests(force: true)
        await refreshEnrichment()
    }

    private func apply(_ error: APIError) {
        switch error.kind {
        case .offline:
            if items.isEmpty {
                notice = Notice(kind: .offline, message: "网络不可用，请检查网络后下拉重试")
            } else {
                let when = lastUpdated.map { RelativeTime.absoluteShort($0) } ?? "之前"
                notice = Notice(kind: .offline, message: "网络不可用，正在显示 \(when) 的缓存")
            }
        case .rateLimited:
            // 真的按服务端说的等，而不是只在横幅里写一句
            if let seconds = error.retryAfter {
                nextAllowedAt = Date().addingTimeInterval(TimeInterval(max(seconds, 1)))
            } else {
                nextAllowedAt = Date().addingTimeInterval(30)
            }
            notice = Notice(kind: .rateLimited, message: error.message)
        case .server, .transport, .decoding:
            notice = Notice(kind: .failed, message: error.message)
        }
    }

    // MARK: - 摘要补全（榜单大卡的正文段落，官网取自 story digest）

    private func refreshDigests(force: Bool) async {
        guard !items.isEmpty else { return }
        if !force, Date().timeIntervalSince(lastDigestFetchAt) < minimumDigestInterval {
            return
        }

        var targets: [(rank: Int, id: String)] = []
        for item in items {
            guard let id = StoryID.publicId(fromStoryLink: item.links?.story) else { continue }
            if !force, digests[id] != nil { continue }
            targets.append((item.rank, id))
        }
        guard !targets.isEmpty else { return }

        lastDigestFetchAt = Date()
        let api = self.api

        // 完全串行：官方明确说过不要在并行里重试，串行换来的是不依赖并发 API、
        // 行为可预测（10 条摘要大约 2–3 秒，列表先出来、摘要随后补上）。
        // 但必须设总时限：弱网下每条最多要等 15 秒超时，10 条就是几分钟，
        // 下拉菊花会一直转。超过时限就带着已有结果收工，下次刷新再补。
        let deadline = Date().addingTimeInterval(8)
        var collected: [Story] = []
        for target in targets {
            if Date() >= deadline { break }
            do {
                let outcome = try await api.story(publicId: target.id)
                switch outcome {
                case .modified(let response):
                    collected.append(response.story)
                    if let digest = response.story.digest, !digest.isEmpty {
                        digests[target.id] = digest
                    }

                case .notModified:
                    // 304 不等于「没内容」：正文在磁盘缓存里，重启后也拿得到
                    if let cached = StoryCache.story(for: target.id) {
                        if let digest = cached.digest, !digest.isEmpty {
                            digests[target.id] = digest
                        }
                    } else {
                        // ETag 还在但正文缓存被清掉了：这次绕开条件请求重取
                        try await fetchStoryIgnoringCache(id: target.id)
                    }
                }
            } catch {
                // 单条失败不影响其它条目
            }
        }

        // 一次编码、一次落盘：逐条写会把整个缓存重复写 10 遍
        StoryCache.store(collected)
    }

    private func fetchStoryIgnoringCache(id: String) async throws {
        let outcome = try await api.story(publicId: id, ignoreCache: true)
        if case .modified(let response) = outcome {
            StoryCache.store(response.story)
            if let digest = response.story.digest, !digest.isEmpty {
                digests[id] = digest
            }
        }
    }

    // MARK: - 网页文本增强（可选，失败即整体退回）

    private func refreshEnrichment(force: Bool = false) async {
        guard AppSettings.isEnrichmentEnabled else {
            enrichment = nil
            return
        }
        if !force, Date().timeIntervalSince(lastEnrichmentAt) < minimumEnrichmentInterval {
            return
        }
        lastEnrichmentAt = Date()

        do {
            let html = try await api.hotPageHTML()
            let text = HTMLTextExtractor.plainText(from: html)
            lastPageText = text
            enrichment = HotPageEnricher.parse(text: text, excludingTitles: items.map { $0.title })
        } catch {
            // 增强只是锦上添花，任何失败都静默回退
            enrichment = nil
        }
    }

    // MARK: - 诊断（网页解析失效时，把这段发出来就能定位问题）

    func diagnosticsText() -> String {
        var lines: [String] = []
        lines.append("AIHOT iOS 诊断")
        lines.append("榜单条数：\(items.count)")
        lines.append("榜单更新时间：\(lastUpdatedText)")
        lines.append("提示：\(notice?.message ?? "无")")
        lines.append("摘要缓存：\(digests.count) 条")
        lines.append("网页增强开关：\(AppSettings.isEnrichmentEnabled ? "开" : "关")")

        if let enrichment = enrichment {
            lines.append("解析出的更新时间：\(enrichment.updatedText ?? "无")")
            for info in enrichment.ranks.sorted(by: { $0.rank < $1.rank }) {
                let heat = info.heat.map { String($0) } ?? "无"
                let delta = info.delta?.text ?? "无"
                lines.append("NO.\(info.rank) 热度=\(heat) 涨跌=\(delta) 爆=\(info.isBreakout) 新=\(info.isNew)")
            }
        } else {
            lines.append("网页增强：未解析出结果（已退回接口字段）")
        }

        if let text = lastPageText {
            lines.append("—— 以下为 /hot 页面提取的纯文本（前 4000 字）——")
            lines.append(String(text.prefix(4000)))
        } else {
            lines.append("—— 没有取到 /hot 页面文本 ——")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 维护

    /// 开关切换后立刻生效（忽略节流）。
    func forceEnrichmentRefresh() async {
        lastEnrichmentAt = .distantPast
        await refreshEnrichment(force: true)
    }

    func clearCache() {
        SnapshotCache.clear()
        StoryCache.clear()
        ETagStore.shared.clear()
        digests = [:]
        enrichment = nil
        lastPageText = nil
        lastAttemptAt = .distantPast
        lastDigestFetchAt = .distantPast
        lastEnrichmentAt = .distantPast
        nextAllowedAt = .distantPast
    }
}
