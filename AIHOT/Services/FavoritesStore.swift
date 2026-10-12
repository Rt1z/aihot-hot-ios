import Combine
import Foundation

/// 收藏（用户数据，不是缓存）。
///
/// 存 UserDefaults 而不是 Caches 目录：Caches 里的东西系统随时会清，
/// `SnapshotCache` / `StoryCache` 放那里是因为它们都能重新拉回来；
/// 而收藏是用户自己一条条攒的，被清掉就是丢数据。`ETagStore` 与
/// `AppSettings` 同样是出于「不能丢」才放 UserDefaults。
///
/// 存的是整个 `HotTopic` 快照而不是只存 id：条目掉出当天的前 10 名之后，
/// 收藏列表照样能离线渲染标题与来源，不必再发请求。
@MainActor
final class FavoritesStore: ObservableObject {

    struct Favorite: Codable, Hashable, Identifiable {
        let topic: HotTopic
        let favoritedAt: Date

        /// 按 id 去重：同一条内容只可能收藏一份。
        var id: String { topic.id }
    }

    /// 顺序即展示顺序：最近收的在最前。靠插入位置维持，不靠排序（见 `load`）。
    @Published private(set) var items: [Favorite] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.load(from: defaults)
    }

    // MARK: - 查询

    func contains(_ topic: HotTopic) -> Bool {
        contains(id: topic.id)
    }

    func contains(id: String) -> Bool {
        items.contains { $0.topic.id == id }
    }

    // MARK: - 变更

    func toggle(_ topic: HotTopic) {
        if contains(id: topic.id) {
            remove(id: topic.id)
        } else {
            add(topic)
        }
    }

    /// `at` 只是为了可测：默认就是「此刻」。
    func add(_ topic: HotTopic, at date: Date = Date()) {
        guard !contains(id: topic.id) else { return }
        items.insert(Favorite(topic: topic, favoritedAt: date), at: 0)
        persist()
    }

    func remove(id: String) {
        items.removeAll { $0.topic.id == id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    // MARK: - 落盘

    /// 数组顺序就是展示顺序（新的在前），所以这里**不排序**：落盘的是哪个顺序，
    /// 读回来就是哪个顺序。
    ///
    /// 特意不写成 `sorted(by: favoritedAt)`：Swift 的 sort 不稳定，同一秒里收藏的
    /// 两条，顺序会在每次重启后随机漂移。顺序的权威是数组本身。
    private static func load(from defaults: UserDefaults) -> [Favorite] {
        guard let data = defaults.data(forKey: AppSettings.favoritesKey) else { return [] }

        if let list = try? JSONDecoder.aihot.decode([Favorite].self, from: data) {
            return list
        }

        // 整体解不出来时逐条抢救。收藏项里包着整条 HotTopic 快照，哪天接口改了字段
        // 让某一条解不动，也不该把用户攒下来的其它收藏一起丢掉。
        return salvage(from: data)
    }

    /// 退化成逐条解码：坏掉的那几条丢掉，其余照常读回来。
    private static func salvage(from data: Data) -> [Favorite] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [Any] else { return [] }

        var recovered: [Favorite] = []
        for element in raw {
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { continue }
            guard let one = try? JSONDecoder.aihot.decode(Favorite.self, from: elementData) else { continue }
            recovered.append(one)
        }
        return recovered
    }

    private func persist() {
        // 与解码对称的编码器（JSONEncoder.aihot），时间同样是 ISO8601；
        // 注意它不带小数秒，所以 favoritedAt 落盘后会截到整秒 ——
        // 界面上只显示到分钟，无所谓。
        guard let data = try? JSONEncoder.aihot.encode(items) else { return }
        defaults.set(data, forKey: AppSettings.favoritesKey)
    }
}
