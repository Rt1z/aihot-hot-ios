import Foundation
import XCTest

final class FixtureAnchor {}

enum FixtureError: Error {
    case missing(String)
}

/// 夹具加载：XcodeGen 可能把资源平铺进测试包，也可能保留 Fixtures 目录，
/// 两种都试一遍。
enum Fixture {

    static func url(_ name: String, ext: String) throws -> URL {
        let bundle = Bundle(for: FixtureAnchor.self)
        let candidates: [URL?] = [
            bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            bundle.url(forResource: name, withExtension: ext)
        ]
        for candidate in candidates {
            if let candidate = candidate, FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // 夹具缺失必须让测试变红：绿色的 CI 不能是假象（skip 会变成假绿）
        XCTFail("夹具 \(name).\(ext) 没有打进测试包（bundle: \(bundle.bundlePath)）")
        throw FixtureError.missing("\(name).\(ext)")
    }

    static func data(_ name: String, ext: String) throws -> Data {
        try Data(contentsOf: try url(name, ext: ext))
    }

    static func text(_ name: String, ext: String) throws -> String {
        let data = try data(name, ext: ext)
        return String(decoding: data, as: UTF8.self)
    }
}
