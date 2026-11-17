import SwiftUI

/// 「练一练」：写作 → 保存 → 对照 → （可选）AI 点评。
///
/// 写作与对照放在**同一个 sheet 的两步**里，而不是保存后 push 到详情页的导航栈：
/// 两个入口（热点详情 / 周报条目详情）分别属于两个不同的 `NavigationStack`，
/// 在里面各注册一遍 destination 只会多出两处容易漂移的接线。
///
/// 全离线可写：草稿按文章落盘（`PracticeStore` 的 drafts），关了 sheet、杀掉 App
/// 再回来都还在。AI 点评是唯一需要网络的步骤，失败只影响那一条点评。
struct PracticeSheet: View {

    let article: PracticeArticle
    /// 周报条目能拿到完整正文；热点只有导读 → nil（点评会明说「基于导读」）。
    let articleText: String?
    let store: PracticeStore

    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case compose
        case contrast
    }

    @State private var step: Step = .compose
    @State private var content: PracticeContent
    @State private var savedEntry: PracticeEntry?
    @State private var selfNote = ""
    @State private var showOriginal = false
    @State private var showFullText = false
    @State private var didRestoreDraft = false

    @State private var draftSaveTask: Task<Void, Never>?
    @State private var noteSaveTask: Task<Void, Never>?
    @State private var reviewTask: Task<Void, Never>?

    @StateObject private var review = PracticeReviewModel()

    init(article: PracticeArticle, articleText: String?, store: PracticeStore) {
        self.article = article
        self.articleText = articleText
        self.store = store
        _content = State(initialValue: .empty(mode: AppSettings.practicePreferredMode))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .compose: composeView
                case .contrast: contrastView
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(step == .compose ? "练一练" : "对照")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(step == .compose ? "取消" : "关闭") {
                        if step == .compose { persistDraftNow() } else { persistNoteNow() }
                        reviewTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step == .compose {
                        Button("保存") { save() }
                            .disabled(!PracticeText.canSave(content))
                    } else {
                        Button("完成") { finish() }
                    }
                }
            }
        }
        .onAppear { restoreDraftIfNeeded() }
        .onDisappear {
            draftSaveTask?.cancel()
            noteSaveTask?.cancel()
            reviewTask?.cancel()
            // 下滑关闭不会经过工具栏按钮：这两条兜底保证草稿与自评不丢
            if step == .compose { persistDraftNow() } else { persistNoteNow() }
        }
        .onChange(of: content) { _ in scheduleDraftSave() }
        .onChange(of: selfNote) { _ in scheduleNoteSave() }
    }

    // MARK: - 写作

    private var composeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                articleHeader
                modePicker

                if content.mode == .structured {
                    structuredEditor
                } else {
                    freeEditor
                }

                sourceCard
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private var kindLabel: String {
        switch article.kind {
        case .hot: return "热点"
        case .reportItem: return "周报条目"
        case .savedLink: return "导入文章"
        }
    }

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if let source = PracticeText.clean(article.sourceName) {
                    Text(source)
                } else {
                    Text("来源未注明")
                }
                Text("·")
                Text(kindLabel)
                Spacer(minLength: 0)
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)
        }
    }

    private var modePicker: some View {
        Picker("写作形式", selection: modeBinding) {
            ForEach(PracticeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var modeBinding: Binding<PracticeMode> {
        Binding(
            get: { content.mode },
            set: { content = PracticeText.transferring(content, to: $0) }
        )
    }

    private var structuredEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    fieldLabel("一句话主旨")
                    Spacer(minLength: 8)
                    let count = PracticeText.wordCount(content.mainIdea)
                    Text("\(count)/60")
                        .font(Typography.meta)
                        .foregroundColor(count > 60 ? Theme.breakout : Theme.textTertiary)
                }
                TextField(
                    "这篇文章讲了什么？尽量一句话说完",
                    text: $content.mainIdea,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .practiceInputStyle()
                .accessibilityIdentifier("practice-main-idea")
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("关键点（最多 3 条）")
                ForEach(0..<3, id: \.self) { index in
                    TextField(
                        "要点 \(index + 1)",
                        text: pointBinding(index),
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                    .practiceInputStyle()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("我的判断")
                TextField(
                    "为什么值得关心？你同意作者吗？",
                    text: $content.takeaway,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .practiceInputStyle()
            }
        }
    }

    private var freeEditor: some View {
        ZStack(alignment: .topLeading) {
            if PracticeText.clean(content.freeText) == nil {
                Text("用你自己的话，把这篇讲清楚。")
                    .font(Typography.body)
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $content.freeText)
                .font(Typography.body)
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 220)
                .padding(8)
                .accessibilityIdentifier("practice-free-text")
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.textSecondary)
    }

    /// 原文只给「导读」就够用：写作时看的是你记住的内容，不是原文。
    /// 周报条目额外说明全文可用于点评。
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 导入文章没有「导读」这一层，只有正文；别摆一个永远为空的分组
            if article.kind != .savedLink {
                DisclosureGroup(isExpanded: $showOriginal) {
                    Text(PracticeText.clean(article.digest) ?? "这篇没有可用的导读，写完后可以点「打开原文」再核对。")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } label: {
                    Text("对照原文导读")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
            }

            if let fullText = PracticeText.clean(articleText) {
                DisclosureGroup(isExpanded: $showFullText) {
                    Text(fullText)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } label: {
                    Text("展开全文（\(PracticeText.wordCount(fullText)) 字）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }

                Text("这篇有完整正文，AI 点评会基于全文。")
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
            }
        }
        .cardBackground()
    }

    // MARK: - 对照

    private var contrastView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let entry = savedEntry {
                    SectionTitle(text: "你写的")
                    PracticeSummaryView(entry: entry)
                        .cardBackground()

                    SectionTitle(text: "对照原文")
                    originalCard

                    SectionTitle(text: "自评")
                    selfNoteCard

                    SectionTitle(text: "AI 点评")
                    reviewSection

                    Button {
                        step = .compose
                    } label: {
                        Label("返回修改", systemImage: "pencil")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                                    .stroke(Theme.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    private var originalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("基准：\(PracticeText.clean(articleText) == nil ? "导读" : "全文")")
                .font(Typography.meta)
                .foregroundColor(Theme.textTertiary)

            if article.kind != .savedLink {
                DisclosureGroup(isExpanded: $showOriginal) {
                    Text(PracticeText.clean(article.digest) ?? "这篇没有可用的导读。")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } label: {
                    Text("展开原文导读")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
            }

            if let fullText = PracticeText.clean(articleText) {
                DisclosureGroup(isExpanded: $showFullText) {
                    Text(fullText)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                } label: {
                    Text("展开全文（\(PracticeText.wordCount(fullText)) 字）")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var selfNoteCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我漏了 / 现在想补充：")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
            TextField(
                "和原文比，你漏了哪一点？（可留空）",
                text: $selfNote,
                axis: .vertical
            )
            .lineLimit(1...4)
            .practiceInputStyle()
            .accessibilityIdentifier("practice-self-note")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if review.isStreaming {
                if PracticeText.clean(review.text) != nil {
                    MarkdownBlocksView(text: review.text)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在点评…")
                            .font(Typography.meta)
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            } else if let snapshot = savedEntry?.review {
                MarkdownBlocksView(text: snapshot.text)
                Text("基于\(snapshot.basis) · \(snapshot.model)")
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
                Button("重新点评") { startReview() }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.accent)
                    .buttonStyle(.plain)
            } else {
                Button {
                    startReview()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("AI 点评")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(hasAIConfig ? Theme.accent : Theme.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasAIConfig)
                .accessibilityIdentifier("practice-review")

                if let notice = review.notice {
                    Text(notice)
                        .font(Typography.meta)
                        .foregroundColor(Theme.breakout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(hasAIConfig
                     ? "会把这篇的材料和你的总结发给你配置的 AI 接口。它只指出遗漏和编造，不会替你重写。"
                     : "还没配好 AI 接口。到「设置 → AI 对话」填写地址、模型和 Key 之后再来。")
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var hasAIConfig: Bool {
        guard let config = AppSettings.currentAIChatConfig() else { return false }
        return !config.apiKey.isEmpty
    }

    // MARK: - 保存与草稿

    private func pointBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { content.points.indices.contains(index) ? content.points[index] : "" },
            set: { value in
                var points = content.points
                while points.count < 3 { points.append("") }
                points[index] = value
                content.points = Array(points.prefix(3))
            }
        )
    }

    private func save() {
        guard PracticeText.canSave(content) else { return }

        let entry: PracticeEntry
        if var existing = savedEntry {
            let changed = !PracticeText.matches(entry: existing, content: content)
            apply(content, to: &existing)
            existing.selfNote = PracticeText.clean(selfNote)
            existing.bodyText = PracticeText.clean(articleText) ?? existing.bodyText
            // 文字改过，旧点评就是针对另一份总结说的 —— 作废，让用户自己决定要不要重跑
            if changed { existing.review = nil }
            entry = existing
        } else {
            entry = PracticeEntry(
                article: article,
                mode: content.mode,
                mainIdea: PracticeText.clean(content.mainIdea),
                points: PracticeText.normalizedPoints(content.points),
                takeaway: PracticeText.clean(content.takeaway),
                freeText: PracticeText.clean(content.freeText),
                bodyText: PracticeText.clean(articleText)
            )
        }

        store.save(entry)
        store.deleteDraft(for: article)
        savedEntry = entry
        selfNote = entry.selfNote ?? ""
        AppSettings.practicePreferredMode = content.mode
        step = .contrast
    }

    private func apply(_ content: PracticeContent, to entry: inout PracticeEntry) {
        entry.mode = content.mode
        switch content.mode {
        case .structured:
            entry.mainIdea = PracticeText.clean(content.mainIdea)
            entry.points = PracticeText.normalizedPoints(content.points)
            entry.takeaway = PracticeText.clean(content.takeaway)
            entry.freeText = nil
        case .free:
            entry.freeText = PracticeText.clean(content.freeText)
            entry.mainIdea = nil
            entry.points = []
            entry.takeaway = nil
        }
    }

    private func finish() {
        persistNoteNow()
        reviewTask?.cancel()
        dismiss()
    }

    private func restoreDraftIfNeeded() {
        guard !didRestoreDraft else { return }
        didRestoreDraft = true
        guard let draft = store.draft(for: article) else { return }
        var points = draft.points
        while points.count < 3 { points.append("") }
        content = PracticeContent(
            mode: draft.mode,
            mainIdea: draft.mainIdea,
            points: Array(points.prefix(3)),
            takeaway: draft.takeaway,
            freeText: draft.freeText
        )
    }

    private func scheduleDraftSave() {
        guard step == .compose else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persistDraftNow()
        }
    }

    private func persistDraftNow() {
        guard step == .compose else { return }
        if PracticeText.isBlank(content) {
            store.deleteDraft(for: article)
            return
        }
        store.saveDraft(
            PracticeDraft(
                article: article,
                mode: content.mode,
                mainIdea: content.mainIdea,
                points: content.points,
                takeaway: content.takeaway,
                freeText: content.freeText,
                updatedAt: Date()
            )
        )
    }

    private func scheduleNoteSave() {
        guard step == .contrast else { return }
        noteSaveTask?.cancel()
        noteSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            persistNoteNow()
        }
    }

    private func persistNoteNow() {
        guard var entry = savedEntry else { return }
        let note = PracticeText.clean(selfNote)
        guard entry.selfNote != note else { return }
        entry.selfNote = note
        store.save(entry)
        savedEntry = entry
    }

    // MARK: - AI 点评

    private func startReview() {
        guard let entry = savedEntry else { return }
        guard let config = AppSettings.currentAIChatConfig(), !config.apiKey.isEmpty else { return }

        let built = PracticeReviewPrompt.make(
            article: entry.article,
            articleText: articleText,
            content: PracticeContent.make(from: entry)
        )

        reviewTask?.cancel()
        reviewTask = Task {
            let text = await review.review(
                config: config,
                system: built.system,
                user: built.user
            )
            guard let text, !Task.isCancelled else { return }
            let snapshot = PracticeReviewSnapshot(
                text: text,
                createdAt: Date(),
                model: config.model,
                basis: built.basis
            )
            store.attachReview(snapshot, to: entry.id)
            savedEntry?.review = snapshot
        }
    }
}

// MARK: - 共用的输入样式

private extension View {
    func practiceInputStyle() -> some View {
        self
            .font(Typography.body)
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Metrics.chipCorner, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.chipCorner, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
