import Combine
import Foundation

/// 订阅页的数据中枢：拉配置、公众号 + B 站取数、合并/分类前排序、缓存与计费闸门。
///
/// 三条会花钱/会丢数据的纪律：
/// 1. 公众号自动刷新每个源 6 小时一次；手动下拉跳过 6 小时门槛，但仍有 60 秒防连点地板。
/// 2. 「上次抓取时间」写进 UserDefaults 且**清缓存不碰** —— 它不是缓存，是计费闸门。
/// 3. 单个源失败只影响它自己：旧条目留着、别的源照常刷新、横幅按来源分开。
@MainActor
final class SubscriptionStore: ObservableObject {

    @Published private(set) var config: SubscriptionConfig?
    @Published private(set) var items: [SubscriptionItem]
    @Published private(set) var notices: [SubscriptionSourceKind: HotTopicsStore.Notice] = [:]
    /// 配置本身的问题（地址没填、拉不到、解析失败），与「某个源取不到」分开。
    @Published private(set) var configNotice: HotTopicsStore.Notice?
    /// 配置里被跳过的坏条目说明。
    @Published private(set) var configWarnings: [String] = []
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded: Bool

    private let configLoader: SubscriptionConfigLoader
    private let rsshub: RSSHubAPI
    private let dajiala: DajialaAPI
    private let snapshotCache: SubscriptionSnapshotCache
    private let defaults: UserDefaults

    /// 设置页「检查/测试」的结果。返回一句话 + 颜色，与现有「测试连接」同构。
    struct Probe {
        let success: Bool
        let message: String
    }

    private var lastBilibiliAttempt: [String: Date] = [:]
    private var lastDajialaCallAt: Date?
    /// 两条线路各自退避：Dajiala 限流不该把免费的 RSSHub 一起停掉。
    private var wechatNextAllowedAt: Date = .distantPast
    private var bilibiliNextAllowedAt: Date = .distantPast

    private let configAutomaticInterval: TimeInterval = 10 * 60
    private let configManualFloor: TimeInterval = 60

    init(
        configLoader: SubscriptionConfigLoader = SubscriptionConfigLoader(),
        rsshub: RSSHubAPI = RSSHubAPI(),
        dajiala: DajialaAPI = DajialaAPI(),
        snapshotCache: SubscriptionSnapshotCache = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.configLoader = configLoader
        self.rsshub = rsshub
        self.dajiala = dajiala
        self.snapshotCache = snapshotCache
        self.defaults = defaults

        let snapshot = snapshotCache.load()
        self.items = snapshot?.items ?? []
        self.lastUpdatedAt = snapshot?.savedAt

        let cached = Self.parseCachedConfig(defaults: defaults)
        self.config = cached.config
        self.configWarnings = cached.warnings
        self.hasLoaded = snapshot != nil || cached.config != nil
    }

    // MARK: - 派生数据

    var enabledWeChatCount: Int {
        config?.wechat.filter(\.isEnabled).count ?? 0
    }

    var enabledBilibiliCount: Int {
        config?.bilibili.filter(\.isEnabled).count ?? 0
    }

    var sourceCounts: (wechat: Int, bilibili: Int) {
        (enabledWeChatCount, enabledBilibiliCount)
    }

    func notice(for kind: SubscriptionSourceKind) -> HotTopicsStore.Notice? {
        notices[kind]
    }

    func items(in topic: SubscriptionTopic) -> [SubscriptionItem] {
        items.filter { $0.topic == topic }
    }

    var itemsByTopic: [(topic: SubscriptionTopic, count: Int)] {
        SubscriptionTopic.allCases.map { topic in
            (topic, items.filter { $0.topic == topic }.count)
        }
    }

    var lastUpdatedText: String {
        guard let lastUpdatedAt = lastUpdatedAt else { return "尚未刷新" }
        return RelativeTime.relative(lastUpdatedAt)
    }

    // MARK: - 刷新

    func refreshIfNeeded() async {
        await refresh(manual: false)
    }

    func refresh(manual: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasLoaded = true
        }

        guard let config = await loadConfigIfNeeded(manual: manual) else {
            return
        }

        var didUpdate = false

        // 公众号：先清掉上一次的横幅；没有源或没 Key 时给出能照着做的说明。
        notices[.wechat] = nil
        let wechatSources = config.wechat.filter(\.isEnabled)
        if !wechatSources.isEmpty {
            if Date() < wechatNextAllowedAt {
                let remaining = Int(wechatNextAllowedAt.timeIntervalSinceNow.rounded(.up))
                if remaining > 0 {
                    notices[.wechat] = HotTopicsStore.Notice(
                        kind: .rateLimited,
                        message: "请求过于频繁，\(remaining) 秒后再试"
                    )
                }
            } else if AIChatSecretStore.shared.dajialaKey().isEmpty {
                notices[.wechat] = HotTopicsStore.Notice(
                    kind: .failed,
                    message: "还没填 Dajiala Key —— 到 设置 → 订阅 填一个；公众号内容暂时取不到"
                )
            } else {
                let key = AIChatSecretStore.shared.dajialaKey()
                let result = await refreshWeChat(
                    sources: wechatSources,
                    apiKey: key,
                    manual: manual
                )
                if result.didUpdate { didUpdate = true }
                if let error = result.error {
                    notices[.wechat] = HotTopicsStore.Notice(
                        kind: error.noticeKind,
                        message: error.message
                    )
                    if let retryAfter = error.retryAfter {
                        wechatNextAllowedAt = Date().addingTimeInterval(TimeInterval(max(retryAfter, 1)))
                    }
                }
            }
        }

        // B 站：免费，失败同样只影响自己。
        notices[.bilibili] = nil
        let bilibiliSources = config.bilibili.filter(\.isEnabled)
        if !bilibiliSources.isEmpty {
            let base = AppSettings.subscriptionRSSHubBaseURL
            if Date() < bilibiliNextAllowedAt {
                let remaining = Int(bilibiliNextAllowedAt.timeIntervalSinceNow.rounded(.up))
                if remaining > 0 {
                    notices[.bilibili] = HotTopicsStore.Notice(
                        kind: .rateLimited,
                        message: "请求过于频繁，\(remaining) 秒后再试"
                    )
                }
            } else if AIChatConfig.normalizedBaseURL(from: base) == nil {
                notices[.bilibili] = HotTopicsStore.Notice(
                    kind: .failed,
                    message: "还没填 RSSHub 地址 —— 到 设置 → 订阅 填写电脑上的 RSSHub"
                )
            } else {
                let result = await refreshBilibili(
                    sources: bilibiliSources,
                    baseURLRaw: base,
                    manual: manual
                )
                if result.didUpdate { didUpdate = true }
                if let error = result.error {
                    notices[.bilibili] = HotTopicsStore.Notice(
                        kind: error.noticeKind,
                        message: error.message
                    )
                    if let retryAfter = error.retryAfter {
                        bilibiliNextAllowedAt = Date().addingTimeInterval(TimeInterval(max(retryAfter, 1)))
                    }
                }
            }
        }

        // 配置为空 = 用户确实没有信源，清空旧条目；配置取不到时 `config` 为 nil，不剪枝。
        let validIDs = config.isEmpty ? Set<String>() : Set(config.enabledSources.map(\.id))
        let normalized = SubscriptionLogic.normalize(items, validSourceIDs: validIDs)
        let changed = normalized != items
        items = normalized

        if didUpdate {
            lastUpdatedAt = Date()
        }
        if didUpdate || changed {
            snapshotCache.save(items: items, at: lastUpdatedAt ?? Date())
        }
    }

    private func refreshWeChat(
        sources: [SubscriptionSource],
        apiKey: String,
        manual: Bool
    ) async -> (didUpdate: Bool, error: SubscriptionError?) {
        var didUpdate = false
        var firstError: SubscriptionError?
        var didCall = false

        for source in sources {
            if Task.isCancelled { break }

            let attempts = AppSettings.subscriptionWeChatLastAttempt
            let lastAttempt = attempts[source.id].map { Date(timeIntervalSince1970: $0) }
            guard SubscriptionRefreshPolicy.shouldRefreshWeChat(
                lastAttemptAt: lastAttempt,
                now: Date(),
                manual: manual
            ) else { continue }

            if didCall {
                let delay = SubscriptionRefreshPolicy.nextDajialaDelay(
                    lastCallAt: lastDajialaCallAt,
                    now: Date()
                )
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            // sleep 被取消时 `try?` 会吞掉错误；这里再拦一次，
            // 否则任务已经取消还会继续发一次付费请求。
            if Task.isCancelled { break }

            // 先记账再发请求：失败也算「试过了」，否则一次网络错误会变成
            // 每进一次 Tab 就再花一次钱的循环。
            var updatedAttempts = AppSettings.subscriptionWeChatLastAttempt
            updatedAttempts[source.id] = Date().timeIntervalSince1970
            AppSettings.subscriptionWeChatLastAttempt = updatedAttempts
            lastDajialaCallAt = Date()
            didCall = true

            do {
                let incoming = try await dajiala.fetchHistory(source: source, apiKey: apiKey)
                items = SubscriptionLogic.merge(
                    existing: items,
                    incoming: incoming,
                    sourceID: source.id
                )
                didUpdate = true
            } catch let error as SubscriptionError {
                if Task.isCancelled { break }
                if firstError == nil || error.priority > firstError!.priority {
                    firstError = error
                }
            } catch {
                if Task.isCancelled { break }
                if firstError == nil {
                    firstError = SubscriptionError(
                        kind: .offline,
                        message: "网络错误：\(error.localizedDescription)"
                    )
                }
            }
        }

        return (didUpdate, firstError)
    }

    private func refreshBilibili(
        sources: [SubscriptionSource],
        baseURLRaw: String,
        manual: Bool
    ) async -> (didUpdate: Bool, error: SubscriptionError?) {
        var didUpdate = false
        var firstError: SubscriptionError?

        for source in sources {
            if Task.isCancelled { break }

            let now = Date()
            guard SubscriptionRefreshPolicy.shouldRefreshBilibili(
                lastAttemptAt: lastBilibiliAttempt[source.id],
                now: now,
                manual: manual
            ) else { continue }
            lastBilibiliAttempt[source.id] = now

            do {
                let feed = try await rsshub.fetch(baseURLRaw: baseURLRaw, source: source)
                items = SubscriptionLogic.merge(
                    existing: items,
                    incoming: feed.items,
                    sourceID: source.id
                )
                didUpdate = true
            } catch let error as SubscriptionError {
                if Task.isCancelled { break }
                if firstError == nil || error.priority > firstError!.priority {
                    firstError = error
                }
            } catch {
                if Task.isCancelled { break }
                if firstError == nil {
                    firstError = SubscriptionError(
                        kind: .offline,
                        message: "网络错误：\(error.localizedDescription)"
                    )
                }
            }
        }

        return (didUpdate, firstError)
    }

    // MARK: - 配置

    private func loadConfigIfNeeded(manual: Bool) async -> SubscriptionConfig? {
        guard let url = AIChatConfig.normalizedBaseURL(from: AppSettings.subscriptionConfigURL) else {
            if config == nil {
                configNotice = HotTopicsStore.Notice(
                    kind: .failed,
                    message: "还没配置订阅：到 设置 → 订阅 填写配置文件地址"
                )
            }
            return config
        }

        let last = AppSettings.subscriptionConfigFetchedAt.map { Date(timeIntervalSince1970: $0) }
        let floor = manual ? configManualFloor : configAutomaticInterval
        if SubscriptionRefreshPolicy.isDue(last: last, now: Date(), floor: floor) {
            do {
                let data = try await configLoader.fetch(url: url)
                let parsed = try SubscriptionConfigParser.parse(data: data)
                config = parsed.config
                configWarnings = parsed.warnings
                configNotice = nil
                AppSettings.subscriptionConfigCache = String(data: data, encoding: .utf8)
                AppSettings.subscriptionConfigFetchedAt = Date().timeIntervalSince1970
            } catch let error as SubscriptionError {
                configNotice = HotTopicsStore.Notice(
                    kind: error.noticeKind,
                    message: error.message
                )
            } catch let error as SubscriptionConfigError {
                configNotice = HotTopicsStore.Notice(
                    kind: .failed,
                    message: error.errorDescription ?? "订阅配置解析失败"
                )
            } catch {
                configNotice = HotTopicsStore.Notice(
                    kind: .failed,
                    message: "订阅配置读取失败：\(error.localizedDescription)"
                )
            }
        }

        if config == nil {
            configNotice = configNotice ?? HotTopicsStore.Notice(
                kind: .failed,
                message: "还没有可用的订阅配置：请检查 设置 → 订阅 里的配置地址"
            )
        }
        return config
    }

    private static func parseCachedConfig(defaults: UserDefaults) -> (config: SubscriptionConfig?, warnings: [String]) {
        guard let raw = defaults.string(forKey: AppSettings.subscriptionConfigCacheKey),
              let data = raw.data(using: .utf8),
              let parsed = try? SubscriptionConfigParser.parse(data: data)
        else {
            return (nil, [])
        }
        return (parsed.config, parsed.warnings)
    }

    // MARK: - 设置页的检查/测试

    func checkConfig() async -> Probe {
        guard let url = AIChatConfig.normalizedBaseURL(from: AppSettings.subscriptionConfigURL) else {
            return Probe(success: false, message: "还没填订阅配置地址")
        }
        do {
            let data = try await configLoader.fetch(url: url)
            let parsed = try SubscriptionConfigParser.parse(data: data)
            config = parsed.config
            configWarnings = parsed.warnings
            configNotice = nil
            AppSettings.subscriptionConfigCache = String(data: data, encoding: .utf8)
            AppSettings.subscriptionConfigFetchedAt = Date().timeIntervalSince1970
            return Probe(
                success: true,
                message: "读到 \(parsed.config.wechat.count) 个公众号 / \(parsed.config.bilibili.count) 个 UP 主"
            )
        } catch let error as SubscriptionError {
            return Probe(success: false, message: error.message)
        } catch let error as SubscriptionConfigError {
            return Probe(success: false, message: error.errorDescription ?? "订阅配置解析失败")
        } catch {
            return Probe(success: false, message: "订阅配置读取失败：\(error.localizedDescription)")
        }
    }

    func testRSSHub() async -> Probe {
        var current = config
        if current == nil {
            current = await loadConfigIfNeeded(manual: true)
        }
        guard let source = current?.bilibili.first(where: \.isEnabled) else {
            return Probe(success: false, message: "配置里没有启用的 B 站订阅")
        }
        do {
            let feed = try await rsshub.fetch(
                baseURLRaw: AppSettings.subscriptionRSSHubBaseURL,
                source: source
            )
            return Probe(success: true, message: "读到 \(feed.items.count) 条")
        } catch let error as SubscriptionError {
            return Probe(success: false, message: error.message)
        } catch {
            return Probe(success: false, message: "RSSHub 读取失败：\(error.localizedDescription)")
        }
    }

    /// 会真实消耗一次 Dajiala 调用，调用方必须先弹确认。
    func testWeChat() async -> Probe {
        var current = config
        if current == nil {
            current = await loadConfigIfNeeded(manual: true)
        }
        guard let source = current?.wechat.first(where: \.isEnabled) else {
            return Probe(success: false, message: "配置里没有启用的公众号")
        }
        let key = AIChatSecretStore.shared.dajialaKey()
        guard !key.isEmpty else {
            return Probe(success: false, message: "还没填 Dajiala Key")
        }
        do {
            let incoming = try await dajiala.fetchHistory(source: source, apiKey: key)
            return Probe(success: true, message: "读到 \(incoming.count) 条")
        } catch let error as SubscriptionError {
            return Probe(success: false, message: error.message)
        } catch {
            return Probe(success: false, message: "Dajiala 读取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 维护

    /// 调试用：抓一次公众号接口的原始响应（会真实计费一次）。
    /// 返回的文本已经脱敏 Key、截断到 2 万字符；调用方负责复制到剪贴板。
    func captureWeChatRaw() async -> (success: Bool, text: String) {
        var current = config
        if current == nil {
            current = await loadConfigIfNeeded(manual: true)
        }
        guard let source = current?.wechat.first(where: \.isEnabled) else {
            return (false, "配置里没有启用的公众号")
        }
        let key = AIChatSecretStore.shared.dajialaKey()
        guard !key.isEmpty else {
            return (false, "还没填 Dajiala Key")
        }
        do {
            let data = try await dajiala.fetchRaw(source: source, apiKey: key)
            var text = String(data: data, encoding: .utf8) ?? ""
            text = text.replacingOccurrences(of: key, with: "***")
            if text.count > 20_000 {
                text = String(text.prefix(20_000)) + "\n…（已截断）"
            }
            if text.isEmpty {
                text = "（响应不是 UTF-8 文本，共 \(data.count) 字节）"
            }
            return (true, text)
        } catch let error as SubscriptionError {
            return (false, error.message)
        } catch {
            return (false, "Dajiala 读取失败：\(error.localizedDescription)")
        }
    }

    /// 只清缓存与内存横幅。**保留**当前条目（界面不白屏）、配置原文、地址、
    /// Key 和公众号计费时间戳（否则一次「清除本地缓存」就会触发一轮付费请求）。
    func clearCache() {
        snapshotCache.clear()
        notices = [:]
        configNotice = nil
        configWarnings = []
        lastBilibiliAttempt = [:]
        wechatNextAllowedAt = .distantPast
        bilibiliNextAllowedAt = .distantPast
        AppSettings.subscriptionConfigFetchedAt = nil
    }
}
