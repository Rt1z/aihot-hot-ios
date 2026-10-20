import Combine
import Foundation

/// 模型榜的数据中枢：按需拉当前分类的榜页、节流、磁盘缓存、详情页内存缓存。
///
/// 榜单没有公开 JSON 接口，页面是整页 HTML（`s-maxage` ≈ 300，无 ETag），
/// 所以这里：只拉用户正在看的那个分类（尊重对方带宽）、刷新节流 300s、
/// 成功后落盘一份快照供冷启动/离线展示；失败保留旧数据 + 横幅。
@MainActor
final class LeaderboardStore: ObservableObject {

    @Published private(set) var boards: [LeaderboardCategory: LeaderboardBoard] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var notice: HotTopicsStore.Notice?
    @Published private(set) var hasLoaded = false

    private let api: AIHOTAPI

    /// 官方约定：榜页共享缓存 ≈ 299s，别拉得更勤。
    private let minimumRefreshInterval: TimeInterval = 300
    /// 详情页 s-maxage ≈ 599。
    private let minimumDetailInterval: TimeInterval = 600

    private var lastFetchAt: [LeaderboardCategory: Date] = [:]
    private var nextAllowedAt: Date = .distantPast
    private var details: [String: (detail: LeaderboardDetail, fetchedAt: Date)] = [:]

    init(api: AIHOTAPI = .shared) {
        self.api = api
        if let saved = LeaderboardCache.load() {
            for board in saved {
                boards[board.category] = board
            }
            hasLoaded = true
        }
    }

    // MARK: - 派生数据

    func board(for category: LeaderboardCategory) -> LeaderboardBoard? {
        boards[category]
    }

    /// 某个分类页头的「N 项评测 · N 家机构 · 更新时间」拼装（缺哪项省哪项）。
    func headerText(for category: LeaderboardCategory) -> String? {
        guard let board = boards[category] else { return nil }
        var parts: [String] = []
        if let evalTotal = board.evalTotal {
            parts.append("\(evalTotal) 项评测")
        }
        if let institutions = board.institutionCount {
            parts.append("\(institutions) 家机构")
        }
        if let updated = board.updatedText {
            parts.append("\(updated) 更新")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 榜页

    /// 拉取某个分类的榜页。节流是无条件的（同热点榜）；本地没这个分类时放宽到 5s。
    func refresh(category: LeaderboardCategory) async {
        guard !isRefreshing else { return }

        let last = lastFetchAt[category] ?? .distantPast
        let floor: TimeInterval = boards[category] == nil ? 5 : minimumRefreshInterval
        if Date().timeIntervalSince(last) < floor {
            return
        }

        if Date() < nextAllowedAt {
            let remaining = Int(nextAllowedAt.timeIntervalSinceNow.rounded(.up))
            if remaining > 0 {
                notice = HotTopicsStore.Notice(kind: .rateLimited, message: "请求过于频繁，\(remaining) 秒后再试")
            }
            return
        }

        isRefreshing = true
        lastFetchAt[category] = Date()
        defer { isRefreshing = false }

        do {
            let html = try await api.leaderboardHTML(path: category.path)
            guard let board = LeaderboardParser.parseBoard(html: html, category: category) else {
                // 解析失败 = 页面改版或返回了别的东西。有旧数据就别覆盖。
                notice = HotTopicsStore.Notice(kind: .failed, message: "榜单格式变了，暂时读不出来；稍后再试，或点页脚链接看网页版")
                return
            }
            boards[category] = board
            notice = nil
            hasLoaded = true
            LeaderboardCache.save(Array(boards.values))
        } catch let error as APIError {
            recordNextAllowed(at: error)
            notice = HotTopicsStore.Notice(kind: kind(of: error), message: error.message)
            hasLoaded = true
        } catch {
            notice = HotTopicsStore.Notice(kind: .failed, message: error.localizedDescription)
            hasLoaded = true
        }
    }

    // MARK: - 详情页

    /// 取某个模型的详情页（内存缓存 + 600s 节流；解析失败返回 nil）。
    func detail(slug: String) async -> LeaderboardDetail? {
        if let cached = details[slug],
           Date().timeIntervalSince(cached.fetchedAt) < minimumDetailInterval {
            return cached.detail
        }

        do {
            let html = try await api.leaderboardHTML(path: "/leaderboard/\(slug)")
            guard let detail = LeaderboardParser.parseDetail(html: html) else {
                // 有旧缓存先用旧的
                return details[slug]?.detail
            }
            details[slug] = (detail, Date())
            return detail
        } catch let error as APIError {
            recordNextAllowed(at: error)
            return details[slug]?.detail
        } catch {
            return details[slug]?.detail
        }
    }

    // MARK: - 私有

    private func recordNextAllowed(at error: APIError) {
        if let seconds = error.retryAfter {
            nextAllowedAt = Date().addingTimeInterval(TimeInterval(seconds))
        }
    }

    private func kind(of error: APIError) -> HotTopicsStore.Notice.Kind {
        switch error.kind {
        case .offline: return .offline
        case .rateLimited: return .rateLimited
        default: return .failed
        }
    }
}

/// 榜单快照（Caches 目录）：只存成功解析过的分类页，冷启动秒开 + 离线兜底。
enum LeaderboardCache {

    private struct Payload: Codable {
        var boards: [LeaderboardBoard]
    }

    private static var fileURL: URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("leaderboard-boards.json")
    }

    static func save(_ boards: [LeaderboardBoard]) {
        guard let url = fileURL, !boards.isEmpty else { return }
        do {
            let data = try JSONEncoder.aihot.encode(Payload(boards: boards))
            try data.write(to: url, options: .atomic)
        } catch {
            // 快照只是加速手段，写失败不影响主流程
        }
    }

    static func load() -> [LeaderboardBoard]? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder.aihot.decode(Payload.self, from: data).boards
        } catch {
            return nil
        }
    }
}
