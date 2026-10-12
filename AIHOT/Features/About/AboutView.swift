import SwiftUI
import UIKit

struct AboutView: View {

    @ObservedObject var store: HotTopicsStore

    @AppStorage(AppSettings.appearanceKey) private var appearance: String = AppSettings.Appearance.system.rawValue
    @AppStorage(AppSettings.enrichmentKey) private var enrichmentEnabled: Bool = true

    @State private var safariURL: URL?
    @State private var copiedDiagnostics = false

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    ForEach(AppSettings.Appearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("从网页补全热度指数", isOn: $enrichmentEnabled)
            } header: {
                Text("数据")
            } footer: {
                Text("官方公开接口不提供热度指数、涨跌与爆/新标记，开启后会额外读取一次热点榜页面文本补全这几项；解析失败会自动退回接口字段（来源数、参与者数），不会显示错误数字。")
            }

            Section("数据来源") {
                Button {
                    safariURL = URL(string: "https://aihot.news/hot")
                } label: {
                    Label("AIHOT · aihot.news", systemImage: "link")
                }
                Button {
                    safariURL = URL(string: "https://aihot.news/terms")
                } label: {
                    Label("使用条款", systemImage: "doc.text")
                }
                Button {
                    safariURL = URL(string: "https://aihot.news/agent")
                } label: {
                    Label("开放接口说明", systemImage: "curlybraces")
                }
            }

            Section {
                Button(role: .destructive) {
                    store.clearCache()
                } label: {
                    Label("清除本地缓存", systemImage: "trash")
                }
            } footer: {
                Text("清除后下次启动需要联网重新拉取榜单快照。")
            }

            Section {
                Button {
                    UIPasteboard.general.string = store.diagnosticsText()
                    copiedDiagnostics = true
                } label: {
                    Label(copiedDiagnostics ? "已复制到剪贴板" : "复制诊断信息", systemImage: "doc.on.doc")
                }
            } header: {
                Text("排查")
            } footer: {
                Text("热度指数或涨跌没有显示时，点这里复制，把内容发出来即可判断是官网改版还是解析问题。")
            }

            Section("关于") {
                LabeledContent("版本", value: versionText)
                LabeledContent("数据接口", value: "/api/v1/hot-topics")
                LabeledContent("用途", value: "个人使用")
            }

            Section {
                Text("内容版权归 AIHOT 及各原始来源所有。本 App 仅作个人阅读使用，不对外分发、不用于商业用途。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: enrichmentEnabled) { isOn in
            guard isOn else { return }
            Task { await store.forceEnrichmentRefresh() }
        }
        .safariSheet(url: $safariURL)
    }
}
