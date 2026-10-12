import Foundation

/// 上一次成功拿到的榜单快照，落在 Caches 目录，用于冷启动秒开与离线查看。
enum SnapshotCache {

    private static var fileURL: URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("hot-topics.json")
    }

    static func save(_ response: HotTopicsResponse) {
        guard let url = fileURL else { return }
        do {
            let data = try JSONEncoder.aihot.encode(response)
            try data.write(to: url, options: .atomic)
        } catch {
            // 快照只是加速手段，写失败不影响主流程
        }
    }

    static func load() -> (response: HotTopicsResponse, savedAt: Date)? {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let response = try JSONDecoder.aihot.decode(HotTopicsResponse.self, from: data)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let savedAt = (attributes?[.modificationDate] as? Date) ?? Date()
            return (response, savedAt)
        } catch {
            return nil
        }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
