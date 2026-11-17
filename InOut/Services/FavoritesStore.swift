import Combine
import Foundation

/// 收藏（用户数据，不是缓存）。
///
/// 存 UserDefaults 而不是 Caches 目录：Caches 里的东西系统随时会清，
/// `SnapshotCache` / `StoryCache` 放那里是因为它们都能重新拉回来；
/// 而收藏是用户自己一条条攒的，被清掉就是丢数据。`ETagStore` 与
/// `AppSettings` 同样是出于「不能丢」才放 UserDefaults。
///
/// 两种收藏共用一个数组、一套顺序：
/// - `.topic`：热点榜的一条（存整个 `HotTopic` 快照，跌出前 10 名也能离线渲染）；
/// - `.link`：从外部收进来的网页（只存链接与标题，见 `SavedLink`）。
///
/// **顺序的权威是数组本身**（新的在前），加载时原样读回。
/// 老版本只写过 `.topic` 形状（没有 `kind` 字段），`Favorite.init(from:)`
/// 会按「有 topic 就是 topic」补上 kind —— 升级不丢收藏。
@MainActor
final class FavoritesStore: ObservableObject {

    struct Favorite: Codable, Hashable, Identifiable {

        enum Kind: String, Codable {
            case topic
            case link
        }

        let kind: Kind
        let topic: HotTopic?
        let link: SavedLink?
        let favoritedAt: Date

        init(kind: Kind, topic: HotTopic? = nil, link: SavedLink? = nil, favoritedAt: Date) {
            self.kind = kind
            self.topic = topic
            self.link = link
            self.favoritedAt = favoritedAt
        }

        /// 按 id 去重：同一条内容只可能收藏一份。链接的 id 带 `link:` 前缀，
        /// 不会和热点 id 撞。
        var id: String {
            switch kind {
            case .topic:
                return topic?.id ?? ""
            case .link:
                return "link:\(link?.url ?? "")"
            }
        }

        static func makeTopic(_ topic: HotTopic, at date: Date) -> Favorite {
            Favorite(kind: .topic, topic: topic, favoritedAt: date)
        }

        static func makeLink(_ link: SavedLink, at date: Date) -> Favorite {
            Favorite(kind: .link, link: link, favoritedAt: date)
        }

        // MARK: - 向后兼容

        private enum CodingKeys: String, CodingKey {
            case kind, topic, link, favoritedAt
        }

        /// 老数据只有 `{topic, favoritedAt}`：缺 `kind` 时按「有没有 topic」推断。
        /// 不这样写的话，升级后收藏会被整体解不出来（`load` 的逐条抢救也救不回）。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            favoritedAt = try container.decode(Date.self, forKey: .favoritedAt)
            topic = try container.decodeIfPresent(HotTopic.self, forKey: .topic)
            link = try container.decodeIfPresent(SavedLink.self, forKey: .link)
            if let raw = try container.decodeIfPresent(String.self, forKey: .kind),
               let decoded = Kind(rawValue: raw) {
                kind = decoded
            } else {
                kind = topic != nil ? .topic : .link
            }
        }
    }

    /// 顺序即展示顺序：最近收的在最前。靠插入位置维持，不靠排序（见 `load`）。
    @Published private(set) var items: [Favorite] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.load(from: defaults)
    }

    /// 从磁盘重新读一次。
    ///
    /// 快捷指令的 App Intent 跑在另一个 `FavoritesStore` 实例里（哪怕同进程，
    /// 也不是 RootView 持有的那个），它写进 UserDefaults 后，界面这份不会自动知道。
    /// App 回到前台时调用一次，导入的链接才会出现 —— 也顺便避免界面之后 persist
    /// 时用旧数组把刚导入的那条覆盖掉。
    func reload() {
        items = Self.load(from: defaults)
    }

    // MARK: - 查询

    func contains(_ topic: HotTopic) -> Bool {
        contains(id: topic.id)
    }

    func contains(id: String) -> Bool {
        items.contains { $0.kind == .topic && $0.topic?.id == id }
    }

    func contains(linkURL: String) -> Bool {
        items.contains { $0.kind == .link && $0.link?.url == linkURL }
    }

    // MARK: - 热点

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
        items.insert(Favorite.makeTopic(topic, at: date), at: 0)
        persist()
    }

    // MARK: - 链接

    /// 返回是否真的加进去了（重复链接返回 false，由界面提示「已在收藏里」）。
    @discardableResult
    func add(link: SavedLink, at date: Date = Date()) -> Bool {
        guard !contains(linkURL: link.url) else { return false }
        items.insert(Favorite.makeLink(link, at: date), at: 0)
        persist()
        return true
    }

    /// 标题是异步抓来的：先以域名兜底入列表，抓到了再原地更新（不改变位置）。
    func updateLinkTitle(url: String, title: String) {
        guard let index = items.firstIndex(where: { $0.kind == .link && $0.link?.url == url }),
              let existing = items[index].link
        else { return }
        let updated = SavedLink(url: existing.url, title: title)
        guard updated.title != existing.title else { return }
        items[index] = Favorite.makeLink(updated, at: items[index].favoritedAt)
        persist()
    }

    func remove(linkURL: String) {
        let before = items.count
        items.removeAll { $0.kind == .link && $0.link?.url == linkURL }
        guard items.count != before else { return }
        persist()
    }

    // MARK: - 删除

    func remove(id: String) {
        items.removeAll { $0.id == id }
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
