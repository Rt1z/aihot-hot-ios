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

    // MARK: - 搜索工具（顺序 / 开关 / 五份 Key 草稿）
    //
    // 顺序与开关**即点即存**（直接写 AppSettings，重启后还在）；
    // Key 仍走草稿 + 保存按钮（钥匙串不逐字写）。初始化读一次 UserDefaults，
    // 之后以 @State 为准。

    @State private var searchOrder: [AppSettings.SearchToolProvider] = AppSettings.searchToolOrder
    @State private var searchDisabled: Set<AppSettings.SearchToolProvider> = AppSettings.searchToolDisabled
    @State private var searchKeyDrafts: [AppSettings.SearchToolProvider: String] = [:]
    @State private var searchFellBack: Set<AppSettings.SearchToolProvider> = []

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
                    Text("联网搜索与读取原文由下一节「搜索工具」按顺序提供，两条协议都能用。")
                    Text("国内直连 api.anthropic.com 通常不通，接口地址可填兼容 Anthropic Messages 协议的中转地址。")
                    Text("「测试连接」只拉一次模型列表，不产生生成计费。")
                    Text("密钥存在系统钥匙串里，只保存在本机。")
                    if secretFellBack || !searchFellBack.isEmpty {
                        Text("注意：这台设备上钥匙串不可用，密钥已改用应用内存储（仅本机、卸载即丢失）。")
                            .foregroundColor(Theme.breakout)
                    }
                }
            }

            // 五家搜索工具：每行一块（开关 + 能力/Key 状态 + Key 输入 + 排序箭头）。
            // 顺序与开关即点即存；Key 走草稿，点「保存密钥」才写钥匙串。
            Section {
                ForEach(searchOrder) { provider in
                    searchProviderBlock(provider)
                }

                Button(action: saveAPIKey) {
                    Label(apiKeySaved ? "已保存密钥" : "保存密钥", systemImage: "key")
                }
                .disabled(!hasAnyKeyDraft)
            } header: {
                Text("搜索工具")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("顺序即优先级：从上往下逐家尝试，一家失败（Key 无效、超限、网络问题）自动换下一家；全部失败时报第一家的错误，先查那家的 Key 或开关。开关与顺序即点即存，Key 要点「保存密钥」。")
                    Text("必填 Key 没填的家不参与（AnySearch 留空即用匿名）；SerpAPI、Serper 只能搜索，读取原文会自动跳过它们。")
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
                Text("清除后下次启动需要联网重新拉取榜单快照。收藏与对话记录不受影响。")
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

    // MARK: - 搜索工具

    private typealias SearchToolProvider = AppSettings.SearchToolProvider

    /// 六份草稿（对话协议 1 + 搜索 5）全空才禁用保存按钮 —— 两个保存按钮共用。
    private var hasAnyKeyDraft: Bool {
        if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return SearchToolProvider.allCases.contains { provider in
            !(searchKeyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func searchKeyDraftBinding(for provider: SearchToolProvider) -> Binding<String> {
        Binding(
            get: { searchKeyDrafts[provider] ?? "" },
            set: { searchKeyDrafts[provider] = $0 }
        )
    }

    /// isOn 是「启用」：停用集合里没有它 = 开着。
    private func searchEnabledBinding(for provider: SearchToolProvider) -> Binding<Bool> {
        Binding(
            get: { !searchDisabled.contains(provider) },
            set: { enabled in
                if enabled {
                    searchDisabled.remove(provider)
                } else {
                    searchDisabled.insert(provider)
                }
                // 即点即存：开关重启后还在
                AppSettings.searchToolDisabled = searchDisabled
            }
        )
    }

    /// ↑↓ 换位。越界由按钮的 disabled 挡，这里再 guard 一次（防御）。
    private func moveSearchTool(_ provider: SearchToolProvider, by offset: Int) {
        guard let index = searchOrder.firstIndex(of: provider) else { return }
        let target = index + offset
        guard target >= 0, target < searchOrder.count else { return }
        searchOrder.swapAt(index, target)
        // 即点即存：顺序重启后还在
        AppSettings.searchToolOrder = searchOrder
    }

    /// 行内 Key 状态提示 —— **显式披露「静默跳过」**：没 Key 的家看起来一切正常、
    /// 就是永远轮不到它，用户不点开永远不知道。
    private func searchKeyHint(for provider: SearchToolProvider) -> (text: String, isWarning: Bool) {
        if searchDisabled.contains(provider) {
            return ("已停用", false)
        }
        let draft = (searchKeyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            return provider.requiresKey ? ("未填 Key，暂不参与", true) : ("留空即用匿名", false)
        }
        return ("已填 Key", false)
    }

    /// 一块 = 一个 Form 行：开关 + 排序箭头，能力标签 + Key 状态，Key 输入框。
    private func searchProviderBlock(_ provider: SearchToolProvider) -> some View {
        let hint = searchKeyHint(for: provider)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(provider.title, isOn: searchEnabledBinding(for: provider))
                    .font(.system(size: 14))
                Spacer()
                // ↑↓ 必须各自 .plain：Form 行里不带样式的按钮共享点击区域，
                // 点一下会把两个动作都触发 —— 中间行先上再下正好抵消，看着就是「按了没反应」
                // （第一/末行不抵消是因为一侧 disabled，所以只有边上能动，更容易误判成「没 bug」）
                HStack(spacing: 16) {
                    Button {
                        moveSearchTool(provider, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(provider == searchOrder.first)
                    Button {
                        moveSearchTool(provider, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(provider == searchOrder.last)
                }
                .font(.system(size: 13))
                .foregroundColor(Theme.textTertiary)
            }
            HStack {
                Text(provider.capabilityTitle)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Text(hint.text)
                    .font(.system(size: 12))
                    .foregroundColor(hint.isWarning ? Theme.breakout : Theme.textSecondary)
            }
            SecureField(
                provider == .anySearch ? "留空即用匿名（限速更低）" : "\(provider.title) 不支持匿名",
                text: searchKeyDraftBinding(for: provider)
            )
            .font(.system(size: 14))
            .foregroundColor(Theme.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
        }
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
        // 五份搜索 Key 一起读：不随开关/顺序重载，草稿才不会丢
        for provider in SearchToolProvider.allCases {
            searchKeyDrafts[provider] = AIChatSecretStore.shared.searchKey(for: provider)
        }
        searchFellBack = Set(SearchToolProvider.allCases.filter {
            AIChatSecretStore.shared.isUsingSearchFallback(for: $0)
        })
        apiKeySaved = false
    }

    private func saveAPIKey() {
        AIChatSecretStore.shared.setKey(apiKeyDraft, for: selectedProtocol)
        for provider in SearchToolProvider.allCases {
            AIChatSecretStore.shared.setSearchKey(
                searchKeyDrafts[provider] ?? "",
                for: provider
            )
        }
        secretFellBack = AIChatSecretStore.shared.isUsingFallback(for: selectedProtocol)
        searchFellBack = Set(SearchToolProvider.allCases.filter {
            AIChatSecretStore.shared.isUsingSearchFallback(for: $0)
        })
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
