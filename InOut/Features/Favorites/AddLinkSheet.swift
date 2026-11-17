import SwiftUI

/// 把外部网页收进收藏。
///
/// **没有分享扩展**：当前的免费 Apple ID + AltStore 分发模式下，分享扩展要跨进程
/// 传数据只能靠 App Group（免费 Personal Team 支持不可靠，AltStore 可能拒签），
/// 而分享扩展也拉不起主 App（Apple 不支持）。所以这里走剪贴板：
/// 微信「…」→「复制链接」→ 打开 App → 「从剪贴板读取」→ 保存。
///
/// 标题可以留空：先按域名兜底，用户也可以点「自动获取标题」抓一次。
/// 抓不到不算失败，绝不编造标题。
struct AddLinkSheet: View {

    @ObservedObject var favorites: FavoritesStore

    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var titleText = ""
    @State private var notice: String?
    @State private var isFetchingTitle = false
    @State private var fetchTask: Task<Void, Never>?
    /// 同一个 URL 不重复自动抓标题；换 URL 才重试。
    @State private var lastFetchAttempt: String?

    private var normalizedURL: URL? {
        SharedLinkURL.normalized(urlText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "https://mp.weixin.qq.com/s/…",
                        text: $urlText,
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("add-link-url")
                } header: {
                    Text("链接")
                } footer: {
                    Text("只接受公开的 http/https 网页；链接里 # 之后的部分会被丢掉。")
                }

                Section {
                    // 用系统 PasteButton：用户点它才算明确粘贴，iOS 16 不会再弹
                    // 一次「允许粘贴」授权。
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        applyPastedText(text)
                    }
                    .accessibilityIdentifier("add-link-paste")
                } header: {
                    Text("从微信导入")
                } footer: {
                    Text("在微信文章页点右上角「…」→「复制链接」，回来点这里。普通网页链接也一样可以存。")
                }

                Section {
                    TextField(
                        "标题（可留空，自动用域名）",
                        text: $titleText,
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                    .accessibilityIdentifier("add-link-title")

                    Button {
                        fetchTitle()
                    } label: {
                        HStack(spacing: 8) {
                            if isFetchingTitle {
                                ProgressView()
                            } else {
                                Image(systemName: "wand.and.stars")
                            }
                            Text(isFetchingTitle ? "正在获取标题…" : "自动获取标题")
                        }
                    }
                    .disabled(normalizedURL == nil || isFetchingTitle)
                    .accessibilityIdentifier("add-link-fetch-title")
                } header: {
                    Text("标题")
                }

                if let notice {
                    Section {
                        Text(notice)
                            .font(Typography.meta)
                            .foregroundColor(Theme.breakout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("添加链接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        fetchTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(normalizedURL == nil)
                        .accessibilityIdentifier("add-link-save")
                }
            }
            .onChange(of: urlText) { _ in scheduleAutoFetch() }
            .onDisappear { fetchTask?.cancel() }
        }
    }

    // MARK: - 动作

    private func save() {
        guard let url = normalizedURL else {
            notice = "只支持公开的 http/https 链接。"
            return
        }
        let link = SavedLink(url: url.absoluteString, title: titleText)
        if favorites.add(link: link) {
            dismiss()
        } else {
            notice = "这条已经在收藏里了。"
        }
    }

    private func applyPastedText(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "剪贴板是空的。"
            return
        }

        guard let candidate = SharedLinkURL.firstURL(in: text)
                ?? SharedLinkURL.normalized(text)?.absoluteString
        else {
            notice = "剪贴板里没有找到公开的 http(s) 链接。"
            return
        }

        urlText = candidate
        notice = nil
        if SharedLinkURL.cleanedTitle(titleText) == nil {
            fetchTitle()
        }
    }

    private func fetchTitle() {
        guard let url = normalizedURL else {
            notice = "先填一个公开的 http(s) 链接。"
            return
        }

        fetchTask?.cancel()
        lastFetchAttempt = url.absoluteString
        isFetchingTitle = true
        notice = nil
        fetchTask = Task { await loadTitle(url) }
    }

    /// URL 一变就（防抖后）自动抓一次标题 —— 用户在「自动获取标题」按钮之外，
    /// 直接粘贴/输入链接也应该看到真实标题。
    private func scheduleAutoFetch() {
        guard !isFetchingTitle, let url = normalizedURL else { return }
        guard SharedLinkURL.cleanedTitle(titleText) == nil else { return }
        guard url.absoluteString != lastFetchAttempt else { return }

        fetchTask?.cancel()
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            lastFetchAttempt = url.absoluteString
            isFetchingTitle = true
            notice = nil
            await loadTitle(url)
        }
    }

    private func loadTitle(_ url: URL) async {
        let title = await LinkTitleService.fetch(url: url)
        guard !Task.isCancelled else {
            isFetchingTitle = false
            return
        }
        isFetchingTitle = false
        if let title, SharedLinkURL.cleanedTitle(titleText) == nil {
            titleText = title
        } else if title == nil {
            notice = "没取到标题，可以自己填，或直接用域名。"
        }
    }
}
