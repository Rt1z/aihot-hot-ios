import Combine
import Foundation

/// 周报/月报的数据中枢：拉最新一期 + 全量索引、节流、磁盘快照、往期详情内存缓存。
///
/// 与模型榜不同，这两个栏目**有公开 JSON 接口**：带 ETag、`s-maxage=300`。
/// 所以节流 300s（本地没有这份数据时放宽到 5s），并按规则 2 处理 304 ——
/// ETag 在 UserDefaults 跨启动保留、快照在 Caches 会被系统清掉，
/// **本地没正文时必须绕开 ETag 重取一次**，否则会永远 304、界面永远空。
///
/// latest 与 index 是**两个独立请求**：一个失败不拖垮另一个
/// （index 成了而 latest 挂了时，往期照样能点进去看）。
/// 一个栏目（周报 / 月报）当前持有的内容。可整体落盘（见 `ReportSnapshotCache`）。
///
/// 放在文件顶层而不是 `ReportStore` 里面：`ReportSnapshotCache` 是非隔离的纯 IO，
/// 拿一个嵌在 `@MainActor` 类型里的 struct 会有全局 actor 推断的麻烦，
/// 顶层声明没有这个问题。
struct ReportKindState: Codable, Equatable {
    var latest: PeriodReport?
    var entries: [ReportEntry] = []
    /// 上一次成功拿到内容的时间（离线横幅的「正在显示 X 的缓存」）。
    var lastUpdated: Date?
    var hasLoaded = false
}

@MainActor
final class ReportStore: ObservableObject {

    @Published private(set) var states: [ReportKind: ReportKindState] = [:]
    /// 横幅按栏目分开：切到月报时不该还挂着「周报暂时取不到」。
    @Published private(set) var notices: [ReportKind: HotTopicsStore.Notice] = [:]
    /// 每个栏目「上次看到的期号」，只用来算 Tab 角标（持久化在 UserDefaults）。
    @Published private(set) var lastSeen: [ReportKind: String] = [:]

    private let api: AIHOTAPI
    private let defaults: UserDefaults

    /// 官方约定：这些端点 `s-maxage=300`，别拉得更勤。
    private let minimumRefreshInterval: TimeInterval = 300

    private var lastAttemptAt: [ReportKind: Date] = [:]
    /// 角标检查是独立的一套节流时间：它只拉 latest，不能占掉 Tab 首次进入时
    /// 那次「latest + 索引」的完整刷新窗口。
    private var lastBadgeCheckAt: [ReportKind: Date] = [:]
    private var nextAllowedAt: Date = .distantPast
    /// 正在进行的完整刷新 / 角标检查，按栏目分开记：两者可以并行，互不吞掉。
    private var inFlight: Set<ReportKind> = []
    private var badgeChecks: Set<ReportKind> = []
    /// 往期详情（key = `weekly-2026-W41`）。已发布的期次不可变，永久内存缓存、不落盘。
    private var details: [String: PeriodReport] = [:]
    /// 条目正文（key = `/items/{id}` 末段）。已发布的条目同样不可变 → 永久内存缓存。
    private var itemBodies: [String: [ReportItemBody.Block]] = [:]
    /// 整页都认不出正文的条目 —— 页面不可变，重试也没有意义，记下来别再打过去。
    private var itemBodyRejected: Set<String> = []
    private var itemBodyAttemptAt: [String: Date] = [:]
    /// 只在**失败**之后当防抖地板：成功与「认不出正文」都会被永久记住，
    /// 所以不会出现同一个 id 反复拉的情况。
    private let itemBodyFloor: TimeInterval = 5

    init(api: AIHOTAPI = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
        if let snapshot = ReportSnapshotCache.load() {
            states = snapshot
        }
        for kind in ReportKind.allCases {
            if let key = defaults.string(forKey: AppSettings.lastSeenReportKey(for: kind)) {
                lastSeen[kind] = key
            }
        }
        seed()
    }

    /// 两个 kind 的键始终存在 —— 之后所有更新都写 `states[kind]?.…`，
    /// 键缺失会让那些赋值静默失效（字典的可选下标赋值不报错）。
    private func seed() {
        for kind in ReportKind.allCases where states[kind] == nil {
            states[kind] = ReportKindState()
        }
    }

    // MARK: - 派生数据

    func state(for kind: ReportKind) -> ReportKindState {
        states[kind] ?? ReportKindState()
    }

    /// 页头那行「2026 年第 42 周 · 10.12 – 10.18」（缺哪项省哪项）。
    func headerText(for kind: ReportKind) -> String? {
        let state = self.state(for: kind)
        guard let report = state.latest else { return nil }
        var parts: [String] = []
        if let key = report.periodKey {
            parts.append(ReportPeriod.title(periodKey: key) ?? key)
        }
        if let range = ReportPeriod.rangeText(start: report.periodStart, end: report.periodEnd) {
            parts.append(range)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 最新一期的「网页版」回链（取不到就退回栏目页）。
    func webURL(for kind: ReportKind) -> URL {
        if let link = state(for: kind).latest?.links?.aihot, let url = URL(string: link) {
            return url
        }
        return URL(string: "https://aihot.news\(kind.webPath)")!
    }

    func notice(for kind: ReportKind) -> HotTopicsStore.Notice? {
        notices[kind]
    }

    /// Tab 上要不要挂「新」：任何一个栏目有未读期就挂。
    var hasUnreadReport: Bool {
        ReportKind.allCases.contains { isUnread($0) }
    }

    func isUnread(_ kind: ReportKind) -> Bool {
        ReportUnread.isUnread(
            latest: state(for: kind).latest?.periodKey,
            lastSeen: lastSeen[kind]
        )
    }

    /// 用户看到了这个栏目 → 把当前期记为已读（没有内容时什么也不做）。
    func markSeen(_ kind: ReportKind) {
        guard let key = state(for: kind).latest?.periodKey else { return }
        setLastSeen(key, for: kind)
    }

    /// 第一次看到某一期时补基线：新装用户不会一打开就挂一个「新」。
    private func observeLatest(_ kind: ReportKind) {
        guard lastSeen[kind] == nil,
              let key = states[kind]?.latest?.periodKey else { return }
        setLastSeen(key, for: kind)
    }

    private func setLastSeen(_ key: String, for kind: ReportKind) {
        guard lastSeen[kind] != key else { return }
        lastSeen[kind] = key
        defaults.set(key, forKey: AppSettings.lastSeenReportKey(for: kind))
    }

    // MARK: - 刷新

    /// 只拉当前分段 —— 不再一次拉两个栏目（另一个等用户切过去再拉）。
    /// Tab 角标要的最新一期由 `checkForNewReports()` 在启动时单独检查。
    func loadIfNeeded(kind: ReportKind) async {
        await refresh(kind: kind)
    }

    /// 拉某个栏目的最新一期与索引。节流是无条件的（同热点榜），没有 force 开关。
    func refresh(kind: ReportKind) async {
        guard !inFlight.contains(kind) else { return }

        let state = self.state(for: kind)
        let floor: TimeInterval = (state.latest == nil && state.entries.isEmpty) ? 5 : minimumRefreshInterval
        let last = lastAttemptAt[kind] ?? .distantPast
        if Date().timeIntervalSince(last) < floor {
            return
        }

        // 服务端明确让我们等（429/503 的 Retry-After），就别再打过去；
        // 但要把「还要等多久」说出来，否则下拉看上去像没反应。
        if Date() < nextAllowedAt {
            let remaining = Int(nextAllowedAt.timeIntervalSinceNow.rounded(.up))
            if remaining > 0 {
                notices[kind] = HotTopicsStore.Notice(kind: .rateLimited, message: "请求过于频繁，\(remaining) 秒后再试")
            }
            return
        }

        inFlight.insert(kind)
        lastAttemptAt[kind] = Date()
        defer {
            inFlight.remove(kind)
            states[kind]?.hasLoaded = true
        }

        await performFetch(kind: kind)
    }

    /// 启动 / 回到前台时只检查各栏目的**最新一期**（不拉索引），给 Tab 角标用。
    ///
    /// 为什么单独一条路径：角标需要在用户没进 Tab 时就知道「有新一期」，
    /// 但又不能因此占掉 Tab 的完整刷新节流；两套时间戳互不影响。
    /// 失败保持安静 —— 真正的刷新失败会由 Tab 里的横幅说出来，角标检查不该弹提示。
    func checkForNewReports() async {
        for kind in ReportKind.allCases {
            guard !badgeChecks.contains(kind) else { continue }
            let last = lastBadgeCheckAt[kind] ?? .distantPast
            guard Date().timeIntervalSince(last) >= minimumRefreshInterval else { continue }
            guard Date() >= nextAllowedAt else { continue }

            badgeChecks.insert(kind)
            lastBadgeCheckAt[kind] = Date()
            defer { badgeChecks.remove(kind) }

            do {
                let outcome = try await fetchLatest(kind)
                switch outcome {
                case .modified(let response):
                    states[kind]?.latest = response.report
                    observeLatest(kind)
                case .notModified:
                    if states[kind]?.latest == nil {
                        // 规则 2：ETag 说没变，但本地没有正文（快照被清了）
                        let retry = try await apiLatest(kind, ignoreCache: true)
                        if case .modified(let response) = retry {
                            states[kind]?.latest = response.report
                            observeLatest(kind)
                        }
                    }
                }
            } catch {
                // 静默：见上
            }
        }
    }

    private func performFetch(kind: ReportKind) async {
        var firstError: APIError?

        // 1) 最新一期
        do {
            let outcome = try await fetchLatest(kind)
            switch outcome {
            case .modified(let response):
                states[kind]?.latest = response.report
            case .notModified:
                if states[kind]?.latest == nil {
                    // 规则 2：304 但本地没有正文（快照被系统清了）→ 这次绕开 ETag 重新要一份
                    let retry = try await apiLatest(kind, ignoreCache: true)
                    if case .modified(let response) = retry {
                        states[kind]?.latest = response.report
                    } else {
                        firstError = APIError(kind: .decoding("304 without body"), message: "周报暂时取不到，请稍后下拉重试")
                    }
                }
            }
        } catch let error as APIError {
            firstError = error
        } catch {
            firstError = APIError(kind: .transport(String(describing: error)), message: "未知错误：\(error.localizedDescription)")
        }

        // 2) 全量索引（与 latest 各自成败，互不阻断）
        do {
            let outcome = try await fetchIndex(kind)
            switch outcome {
            case .modified(let response):
                states[kind]?.entries = response.items
            case .notModified:
                if states[kind]?.entries.isEmpty == true {
                    let retry = try await apiIndex(kind, ignoreCache: true)
                    if case .modified(let response) = retry {
                        states[kind]?.entries = response.items
                    } else if firstError == nil {
                        firstError = APIError(kind: .decoding("304 without body"), message: "往期列表暂时取不到，请稍后下拉重试")
                    }
                }
            }
        } catch let error as APIError {
            if firstError == nil { firstError = error }
        } catch {
            if firstError == nil {
                firstError = APIError(kind: .transport(String(describing: error)), message: "未知错误：\(error.localizedDescription)")
            }
        }

        // 3) 往期列表不重复列最新一期（两个请求谁先到都按最终结果剔）
        if let latestKey = states[kind]?.latest?.periodKey {
            states[kind]?.entries = (states[kind]?.entries ?? []).filter { $0.periodKey != latestKey }
        }

        if let error = firstError {
            apply(error, kind: kind)
        } else {
            states[kind]?.lastUpdated = Date()
            notices[kind] = nil
            observeLatest(kind)
            ReportSnapshotCache.save(states)
        }
    }

    private func apiLatest(_ kind: ReportKind, ignoreCache: Bool) async throws -> LoadOutcome<ReportResponse> {
        switch kind {
        case .weekly: return try await api.weeklyLatest(ignoreCache: ignoreCache)
        case .monthly: return try await api.monthlyLatest(ignoreCache: ignoreCache)
        }
    }

    private func fetchLatest(_ kind: ReportKind) async throws -> LoadOutcome<ReportResponse> {
        try await apiLatest(kind, ignoreCache: false)
    }

    private func apiIndex(_ kind: ReportKind, ignoreCache: Bool) async throws -> LoadOutcome<ReportIndexResponse> {
        switch kind {
        case .weekly: return try await api.weeklyIndex(ignoreCache: ignoreCache)
        case .monthly: return try await api.monthlyIndex(ignoreCache: ignoreCache)
        }
    }

    private func fetchIndex(_ kind: ReportKind) async throws -> LoadOutcome<ReportIndexResponse> {
        try await apiIndex(kind, ignoreCache: false)
    }

    // MARK: - 往期详情

    /// 取某一期全文（内存缓存 + 600s…不，同样是 300s：这些端点都是 `s-maxage=300`）。
    /// 失败返回 nil，详情页自己显示空态（含 problem+json 之外的通用文案）。
    func report(kind: ReportKind, period: String) async -> PeriodReport? {
        let key = "\(kind.rawValue)-\(period)"
        if let cached = details[key] {
            return cached
        }

        do {
            let outcome = try await apiReport(kind, period: period, ignoreCache: false)
            switch outcome {
            case .modified(let response):
                details[key] = response.report
                return response.report
            case .notModified:
                // 本地没有这一期却收到 304 —— 规则 2，绕开 ETag 再要一次
                let retry = try await apiReport(kind, period: period, ignoreCache: true)
                if case .modified(let response) = retry {
                    details[key] = response.report
                    return response.report
                }
                return nil
            }
        } catch let error as APIError {
            recordNextAllowed(at: error)
            return nil
        } catch {
            return nil
        }
    }

    private func apiReport(_ kind: ReportKind, period: String, ignoreCache: Bool) async throws -> LoadOutcome<ReportResponse> {
        switch kind {
        case .weekly: return try await api.weeklyReport(period: period, ignoreCache: ignoreCache)
        case .monthly: return try await api.monthlyReport(period: period, ignoreCache: ignoreCache)
        }
    }

    // MARK: - 条目正文（`/items/{id}`）

    /// 一条新闻的站内页正文。取不到（没链接 / 页面认不出 / 网络失败）返回 nil，
    /// 详情页退回「AI 导读 + 打开原文」那一版 —— 宁可少显示，不显示半个页面。
    ///
    /// 与往期详情同一条理由：**已发布的条目不可变** → 成功或「认不出正文」都记下来，
    /// 同一个 id 一个会话里只打一次网络；只有失败才留 5 秒地板等重试。
    /// 这一页**没有 ETag**，所以规则 2 的 304-无正文坑在这里不存在；
    /// 但 429/503 的 `Retry-After` 全局闸门照旧要过。
    func itemBody(link: String?) async -> [ReportItemBody.Block]? {
        guard let id = ReportItemID.id(fromItemLink: link) else { return nil }
        if let cached = itemBodies[id] { return cached }
        if itemBodyRejected.contains(id) { return nil }

        let last = itemBodyAttemptAt[id] ?? .distantPast
        guard Date().timeIntervalSince(last) >= itemBodyFloor else { return nil }
        guard Date() >= nextAllowedAt else { return nil }

        itemBodyAttemptAt[id] = Date()
        do {
            let html = try await api.itemHTML(id: id)
            if let blocks = ReportItemBody.parse(html: html) {
                itemBodies[id] = blocks
                return blocks
            }
            // 已发布条目不可变 —— 这一页就是没有 `<div class="prose">`，再拉一百次也一样
            itemBodyRejected.insert(id)
            return nil
        } catch let error as APIError {
            recordNextAllowed(at: error)
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - 缓存清理（设置页「清除本地缓存」）

    /// 只清周报/月报自己的快照与内存：**收藏、对话记录一概不动**（规则 6）。
    /// ETag 不在这里清 —— `HotTopicsStore.clearCache()` 里的 `ETagStore.shared.clear()`
    /// 清的是整个 `aihot.etag.` 前缀，两个动作由设置页一起调。
    /// 界面上正在看的内容（`states`）保留，与热点榜清缓存后榜单仍在一致。
    func clearCache() {
        ReportSnapshotCache.clear()
        details = [:]
        itemBodies = [:]
        itemBodyRejected = []
        itemBodyAttemptAt = [:]
        lastAttemptAt = [:]
        nextAllowedAt = .distantPast
    }

    // MARK: - 私有

    private func recordNextAllowed(at error: APIError) {
        if let seconds = error.retryAfter {
            nextAllowedAt = Date().addingTimeInterval(TimeInterval(max(seconds, 1)))
        }
    }

    private func apply(_ error: APIError, kind: ReportKind) {
        switch error.kind {
        case .offline:
            let when = state(for: kind).lastUpdated.map { RelativeTime.absoluteShort($0) }
            if let when = when {
                notices[kind] = HotTopicsStore.Notice(kind: .offline, message: "网络不可用，正在显示 \(when) 的缓存")
            } else {
                notices[kind] = HotTopicsStore.Notice(kind: .offline, message: "网络不可用，请检查网络后下拉重试")
            }
        case .rateLimited:
            // 真的按服务端说的等，而不是只在横幅里写一句
            recordNextAllowed(at: error)
            if error.retryAfter == nil {
                nextAllowedAt = Date().addingTimeInterval(30)
            }
            notices[kind] = HotTopicsStore.Notice(kind: .rateLimited, message: error.message)
        case .server, .transport, .decoding:
            notices[kind] = HotTopicsStore.Notice(kind: .failed, message: error.message)
        }
    }
}

/// 周报/月报快照（Caches 目录）：只存成功拿到的内容，冷启动秒开 + 离线兜底。
/// 用两个显式字段而不是 `[ReportKind: ReportKindState]` 字典 ——
/// 枚举键的字典会编码成「键值交替的数组」，可读性和兼容性都差。
enum ReportSnapshotCache {

    private struct Payload: Codable {
        var weekly: ReportKindState?
        var monthly: ReportKindState?
    }

    private static var fileURL: URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("period-reports.json")
    }

    static func save(_ states: [ReportKind: ReportKindState]) {
        guard let url = fileURL else { return }
        let payload = Payload(
            weekly: states[.weekly],
            monthly: states[.monthly]
        )
        // 两份都是空的就没什么可存的
        guard payload.weekly != nil || payload.monthly != nil else { return }
        do {
            let data = try JSONEncoder.aihot.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // 快照只是加速手段，写失败不影响主流程
        }
    }

    static func load() -> [ReportKind: ReportKindState]? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let payload = try JSONDecoder.aihot.decode(Payload.self, from: data)
            var states: [ReportKind: ReportKindState] = [:]
            if let weekly = payload.weekly { states[.weekly] = weekly }
            if let monthly = payload.monthly { states[.monthly] = monthly }
            return states.isEmpty ? nil : states
        } catch {
            return nil
        }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
