import Foundation

struct SubscriptionSnapshot: Codable, Equatable {
    var version: Int = 1
    var savedAt: Date
    var items: [SubscriptionItem]
}

/// 订阅条目的磁盘快照（`Caches/subscriptions.json`）。
///
/// 与收藏不同：这是**缓存**，系统可以在空间紧张时清掉；丢了最多是冷启动要联网重拉。
/// 写失败静默（缓存丢了可恢复），但编码失败不写空数组 —— 那会把上一份好数据覆盖掉。
final class SubscriptionSnapshotCache {

    static let shared = SubscriptionSnapshotCache()

    private let fileURL: URL

    init(fileURL: URL = SubscriptionSnapshotCache.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("subscriptions.json")
    }

    func load() -> SubscriptionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder.aihot.decode(SubscriptionSnapshot.self, from: data)
    }

    func save(items: [SubscriptionItem], at date: Date = Date()) {
        let snapshot = SubscriptionSnapshot(savedAt: date, items: items)
        guard let data = try? JSONEncoder.aihot.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
