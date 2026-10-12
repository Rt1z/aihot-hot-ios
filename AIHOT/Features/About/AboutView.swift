import SwiftUI
import UIKit

struct AboutView: View {

    @ObservedObject var store: HotTopicsStore
    @ObservedObject var favorites: FavoritesStore

    @AppStorage(AppSettings.appearanceKey) private var appearance: String = AppSettings.Appearance.system.rawValue
    @AppStorage(AppSettings.enrichmentKey) private var enrichmentEnabled: Bool = true

    @State private var safariURL: URL?
    @State private var copiedDiagnostics = false
    @State private var showClearFavorites = false

    // MARK: - AI 对话配置
    //
    // 每个协议各一套地址与模型，都用**字面量键**的 @AppStorage：
    // 用「由另一个 @AppStorage 算出来的键」会在每次 body 求值时重建包装器、读到陈旧值。

    @AppStorage(AppSettings.aiChatProtocolKey)
    private var aiChatProtocolRaw: String = AIChatProtocol.anthropicMessages.rawValue
    @AppStorage(AppSettings.aiChatAnthropicBaseURLKey)
    private var anthropicBaseURL: String = AIChatProtocol.anthropicMessages.defaultBaseURL
    @AppStorage(AppSettings.aiChatAnthropicModelKey)
    private var anthropicModel: String = AIChatProtocol.anthropicMessages.defaultModel
    @AppStorage(AppSettings.aiChatOpenAIBaseURLKey)
    private var openAIBaseURL: String = ""
    @AppStorage(AppSettings.aiChatOpenAIModelKey)
    private var openAIModel: String = ""

    /// 密钥不进 @AppStorage（那会每敲一个字写一次钥匙串），显式保存。
    @State private var apiKeyDraft = ""
    @State private var apiKeySaved = false
    @State private var secretFellBack = false
    /// AnySearch 的 Key 是**可选**的：留空走匿名，搜索照样能用。
    @State private var anySearchKeyDraft = ""
    @State private var anySearchFellBack = false

    @State private var isTestingConnection = false
    @State private var testResult: String?
    @State private var testFailed = false

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            settingsForm
        }
        .tint(Theme.accent)
    }

    private var settingsForm: some View {
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

            Section {
                Picker("协议", selection: $aiChatProtocolRaw) {
                    ForEach(AIChatProtocol.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                // 标签单独一行而不是塞进 TextField 的 placeholder：
                // 这两个字段默认就有值，placeholder 在填好之后就看不见了，
                // 那样一行只剩个光秃秃的 URL。
                VStack(alignment: .leading, spacing: 4) {
                    Text("接口地址")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                    TextField("https://api.anthropic.com", text: baseURLBinding)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("模型")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                    TextField(selectedProtocol.modelPlaceholder, text: modelBinding)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                    SecureField("sk-…", text: $apiKeyDraft)
                        // 少了这几行，iOS 16 会把它当密码去自动填充、还会把首字母大写
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("AnySearch Key（可选）")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                    SecureField("留空即用匿名（限速更低）", text: $anySearchKeyDraft)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                }

                Button(action: saveAPIKey) {
                    Label(apiKeySaved ? "已保存密钥" : "保存密钥", systemImage: "key")
                }
                .disabled(
                    apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && anySearchKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Button {
                    Task { await testConnection() }
                } label: {
                    Label(
                        isTestingConnection ? "正在测试…" : "测试连接",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
                .disabled(isTestingConnection)

                if let testResult = testResult {
                    Text(testResult)
                        .font(.system(size: 12))
                        .foregroundColor(testFailed ? Theme.breakout : Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("AI 对话")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("联网搜索与读取原文由 AnySearch 提供，两条协议都能用；AnySearch Key 留空即用匿名（限速更低）。")
                    Text("国内直连 api.anthropic.com 通常不通，接口地址可填兼容 Anthropic Messages 协议的中转地址。")
                    Text("「测试连接」只拉一次模型列表，不产生生成计费。")
                    Text("密钥存在系统钥匙串里，只保存在本机。")
                    if secretFellBack {
                        Text("注意：这台设备上钥匙串不可用，密钥已改用应用内存储（仅本机、卸载即丢失）。")
                            .foregroundColor(Theme.breakout)
                    }
                }
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
                Text("清除后下次启动需要联网重新拉取榜单快照。收藏不受影响。")
            }

            Section {
                LabeledContent("已收藏", value: "\(favorites.items.count) 条")
                Button(role: .destructive) {
                    showClearFavorites = true
                } label: {
                    Label("清空收藏", systemImage: "bookmark.slash")
                }
                .disabled(favorites.items.isEmpty)
            } header: {
                Text("收藏")
            } footer: {
                Text("收藏只保存在这台设备上，在详情页点右上角书签即可添加。清空后无法恢复。")
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
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: enrichmentEnabled) { isOn in
            guard isOn else { return }
            Task { await store.forceEnrichmentRefresh() }
        }
        // 收藏是用户数据，清空不可恢复，比「清除本地缓存」更该问一句
        .confirmationDialog("确定清空全部收藏？", isPresented: $showClearFavorites, titleVisibility: .visible) {
            Button("清空收藏", role: .destructive) { favorites.clear() }
            Button("取消", role: .cancel) { }
        }
        .task { loadAPIKey() }
        // 切协议必须重读密钥草稿：否则会把 A 协议的 Key 存进 B 协议
        .onChange(of: aiChatProtocolRaw) { _ in
            loadAPIKey()
            testResult = nil
        }
        .safariSheet(url: $safariURL)
    }

    // MARK: - AI 对话配置

    private var selectedProtocol: AIChatProtocol {
        AIChatProtocol(rawValue: aiChatProtocolRaw) ?? .anthropicMessages
    }

    private var baseURLBinding: Binding<String> {
        switch selectedProtocol {
        case .anthropicMessages: return $anthropicBaseURL
        case .openAICompatible: return $openAIBaseURL
        }
    }

    private var modelBinding: Binding<String> {
        switch selectedProtocol {
        case .anthropicMessages: return $anthropicModel
        case .openAICompatible: return $openAIModel
        }
    }

    private func loadAPIKey() {
        apiKeyDraft = AIChatSecretStore.shared.key(for: selectedProtocol)
        secretFellBack = AIChatSecretStore.shared.isUsingFallback(for: selectedProtocol)
        anySearchKeyDraft = AIChatSecretStore.shared.anySearchKey()
        anySearchFellBack = AIChatSecretStore.shared.isUsingAnySearchFallback()
        apiKeySaved = false
    }

    private func saveAPIKey() {
        AIChatSecretStore.shared.setKey(apiKeyDraft, for: selectedProtocol)
        AIChatSecretStore.shared.setAnySearchKey(anySearchKeyDraft)
        secretFellBack = AIChatSecretStore.shared.isUsingFallback(for: selectedProtocol)
        anySearchFellBack = AIChatSecretStore.shared.isUsingAnySearchFallback()
        apiKeySaved = true
    }

    private func testConnection() async {
        guard let config = AIChatConfig.resolve(
            chatProtocol: selectedProtocol,
            baseURLRaw: baseURLBinding.wrappedValue,
            modelRaw: modelBinding.wrappedValue,
            apiKey: apiKeyDraft
        ) else {
            testResult = "配置不完整：请检查接口地址与模型"
            testFailed = true
            return
        }
        guard !config.apiKey.isEmpty else {
            testResult = "还没填 API Key"
            testFailed = true
            return
        }

        isTestingConnection = true
        defer { isTestingConnection = false }

        switch await AIChatAPI.shared.testConnection(config: config) {
        case .success(let message):
            testResult = message
            testFailed = false
        case .failure(let error):
            testResult = error.message
            testFailed = true
        }
    }
}
