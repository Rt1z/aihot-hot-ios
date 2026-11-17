import SwiftUI
import UIKit

struct AboutView: View {

    @ObservedObject var store: HotTopicsStore
    @ObservedObject var favorites: FavoritesStore
    @ObservedObject var reports: ReportStore

    @AppStorage(AppSettings.appearanceKey) private var appearance: String = AppSettings.Appearance.system.rawValue
    @AppStorage(AppSettings.enrichmentKey) private var enrichmentEnabled: Bool = true

    @State private var safariURL: URL?
    @State private var copiedDiagnostics = false
    @State private var copiedRunDiagnostics = false
    @State private var showClearFavorites = false
    @State private var showClearChatHistory = false

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

    // MARK: - 腾讯云元宝搜索（SecretId / SecretKey 草稿 + 探测）
    //
    // 密钥仍走草稿 + 保存按钮（钥匙串不逐字写）。初始化读一次，之后以 @State 为准。

    @State private var tencentSecretIdDraft = ""
    @State private var tencentSecretKeyDraft = ""
    @State private var searchFellBack = false
    /// 「测试搜索」的行内结果；改草稿即清（避免旧结果误导）。
    @State private var searchProbe: KeyProbe?

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

                Button(action: saveAPIKey) {
                    Label(apiKeySaved ? "已保存密钥" : "保存密钥", systemImage: "key")
                }
                .disabled(!hasAnyKeyDraft)

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
                    Text("联网搜索与读取原文由下一节「联网搜索」提供（元宝搜索 + App 内抓网页），两条协议都能用。")
                    Text("国内直连 api.anthropic.com 通常不通，接口地址可填兼容 Anthropic Messages 协议的中转地址。")
                    Text("「测试连接」只拉一次模型列表，不产生生成计费。")
                    Text("密钥存在系统钥匙串里，只保存在本机。")
                    if secretFellBack || searchFellBack {
                        Text("注意：这台设备上钥匙串不可用，密钥已改用应用内存储（仅本机、卸载即丢失）。")
                            .foregroundColor(Theme.breakout)
                    }
                }
            }

            // 联网搜索只有一家：腾讯云元宝搜索。搜索走 SearchPro；读网页由 App 自己抓。
            Section {
                TextField("SecretId", text: $tencentSecretIdDraft)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier("tencent-secret-id")
                    .onChange(of: tencentSecretIdDraft) { _ in
                        searchProbe = nil
                    }

                SecureField("SecretKey", text: $tencentSecretKeyDraft)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .accessibilityIdentifier("tencent-secret-key")
                    .onChange(of: tencentSecretKeyDraft) { _ in
                        searchProbe = nil
                    }

                Button(action: saveAPIKey) {
                    Label(apiKeySaved ? "已保存密钥" : "保存密钥", systemImage: "key")
                }
                .disabled(!hasAnyKeyDraft)

                Button {
                    Task { await probeSearch() }
                } label: {
                    Label(
                        searchProbe == .running ? "正在测试…" : "测试搜索",
                        systemImage: "magnifyingglass"
                    )
                }
                .disabled(searchProbe == .running || !hasTencentSecretDraft)

                if searchProbe == .ok {
                    Text("✓ 元宝搜索已连通")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                if case .failed(let message)? = searchProbe {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.breakout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("联网搜索（腾讯云元宝搜索）")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("元宝搜索是腾讯云的付费产品：先在腾讯云控制台开通，再到「访问管理 → API 密钥管理」创建 SecretId / SecretKey。")
                    Text("搜索由元宝搜索（SearchPro）执行；读取网页正文由 App 直接抓取，不走腾讯云。")
                    Text("「测试搜索」会发一次真实搜索、消耗一次额度；密钥要点「保存密钥」才参与对话。")
                    Text("密钥存在系统钥匙串里，只保存在本机。")
                    if searchFellBack {
                        Text("注意：这台设备上钥匙串不可用，搜索密钥已改用应用内存储（仅本机、卸载即丢失）。")
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
                    reports.clearCache()
                } label: {
                    Label("清除本地缓存", systemImage: "trash")
                }
            } footer: {
                Text("清除后下次启动需要联网重新拉取榜单与周报快照。收藏、对话记录与练习记录不受影响。")
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
                Text("收藏只保存在这台设备上：热点条目在详情页点右上角书签，网页链接用收藏页右上角的「+」添加。清空后无法恢复。")
            }

            // 对话是用户数据（Application Support），清空同样要先问一句
            Section {
                Button(role: .destructive) {
                    showClearChatHistory = true
                } label: {
                    Label("清除对话记录", systemImage: "bubble.left.and.bubble.right.slash")
                }
            } header: {
                Text("对话记录")
            } footer: {
                Text("对话按新闻自动保存，按最后更新最多保留最近 50 条会话，超出淘汰最旧；「清除本地缓存」不影响对话记录。")
            }

            Section {
                Button {
                    UIPasteboard.general.string = DiagnosticReport.capture(
                        hot: store,
                        favorites: favorites,
                        reports: reports
                    )
                    copiedRunDiagnostics = true
                } label: {
                    Label(copiedRunDiagnostics ? "已复制到剪贴板" : "复制运行诊断", systemImage: "doc.on.doc")
                }

                Button {
                    UIPasteboard.general.string = store.diagnosticsText()
                    copiedDiagnostics = true
                } label: {
                    Label(copiedDiagnostics ? "已复制到剪贴板" : "复制热度解析诊断", systemImage: "doc.text.magnifyingglass")
                }
            } header: {
                Text("排查")
            } footer: {
                Text("「复制运行诊断」包含版本号（可与安装包对应）、系统与机型、各栏目的条数/更新时间/提示、AI 对话与联网搜索的配置状态；不含 API Key，接口地址只保留主机名。任何异常都先发它。「复制热度解析诊断」另含 /hot 页面提取的原文，只在热度指数或涨跌没有显示时用。")
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
        .confirmationDialog("确定清除全部对话记录？", isPresented: $showClearChatHistory, titleVisibility: .visible) {
            Button("清除对话记录", role: .destructive) { ChatHistoryStore.shared.clear() }
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

    // MARK: - 联网搜索（腾讯云元宝搜索）

    /// 两个「保存密钥」共用。**有已保存的值时也要允许保存** —— 否则把最后一个
    /// 字段清空后按钮就灰了，用户没法保存「清空」这个动作。
    private var hasAnyKeyDraft: Bool {
        if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !tencentSecretIdDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !tencentSecretKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }

        let secret = AIChatSecretStore.shared
        return !secret.key(for: selectedProtocol).isEmpty
            || !secret.tencentSecretId().isEmpty
            || !secret.tencentSecretKey().isEmpty
    }

    private var hasTencentSecretDraft: Bool {
        !tencentSecretIdDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !tencentSecretKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 用当前草稿发一次真实搜索（消耗一次额度）。错误文案就是 runner 原文。
    private func probeSearch() async {
        guard searchProbe != .running else { return }

        let config = TencentWSAConfig(
            secretId: tencentSecretIdDraft,
            secretKey: tencentSecretKeyDraft
        )
        guard config.isConfigured else {
            searchProbe = .failed("SecretId 和 SecretKey 都要填")
            return
        }

        searchProbe = .running
        let runner = TencentWSARunner(config: config)
        let call = AIChatToolCall(
            index: 0, id: "key-probe", name: AIChatToolName.webSearch,
            argumentsJSON: #"{"query":"腾讯云"}"#
        )
        let result = await runner.execute(call: call)
        searchProbe = result.isError ? .failed(result.text) : .ok
    }

    private enum KeyProbe: Equatable {
        case running
        case ok
        case failed(String)
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
        let secret = AIChatSecretStore.shared
        apiKeyDraft = secret.key(for: selectedProtocol)
        secretFellBack = secret.isUsingFallback(for: selectedProtocol)
        tencentSecretIdDraft = secret.tencentSecretId()
        tencentSecretKeyDraft = secret.tencentSecretKey()
        searchFellBack = secret.isUsingTencentSecretIdFallback()
            || secret.isUsingTencentSecretKeyFallback()
        apiKeySaved = false
    }

    private func saveAPIKey() {
        let secret = AIChatSecretStore.shared
        secret.setKey(apiKeyDraft, for: selectedProtocol)
        secret.setTencentSecretId(tencentSecretIdDraft)
        secret.setTencentSecretKey(tencentSecretKeyDraft)
        secretFellBack = secret.isUsingFallback(for: selectedProtocol)
        searchFellBack = secret.isUsingTencentSecretIdFallback()
            || secret.isUsingTencentSecretKeyFallback()
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
