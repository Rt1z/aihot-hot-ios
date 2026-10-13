import Foundation
import SwiftUI

/// 详情页的「AI 对话」弹窗。
///
/// 刻意没有用 `.presentationDetents`：它在 iOS 16.0 上存在，但和键盘避让的配合
/// 在早期 16.x 上是坏的（输入框会被键盘盖住），而我们没法在本地预演。用默认的全高。
struct AIChatView: View {

    let item: HotTopic
    let story: Story?
    let prefetchedDigest: String?

    @StateObject private var model: AIChatModel
    @Environment(\.dismiss) private var dismiss

    /// sessionKey 用 `item.id`（HotTopic 的 id，非可选）：同一条新闻的对话存在
    /// 同一个 key 下，杀掉 App 重开还在。autoclosure 捕获的是 **init 参数** `item`，
    /// 不引用 self，没有「初始化前用 self」的问题；首次渲染前就恢复完毕，无空屏闪烁。
    init(item: HotTopic, story: Story?, prefetchedDigest: String?) {
        self.item = item
        self.story = story
        self.prefetchedDigest = prefetchedDigest
        _model = StateObject(wrappedValue: AIChatModel(sessionKey: item.id))
    }

    private static let suggestions = ["这条为什么火？", "用三句话讲清楚", "还有后续吗？"]
    /// 底部哨兵：滚到它比滚到「最后一条消息」稳 —— 那条消息还在长高的时候 scrollTo 会跳。
    private static let bottomAnchor = "ai-chat-bottom"

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            model.reset()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(model.messages.isEmpty)
                        .accessibilityLabel("清空对话")
                    }
                }
        }
        // 关窗即停：不停的话请求会继续跑、继续计费，而界面上已经看不见了。
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if model.messages.isEmpty {
            emptyState
        } else {
            transcript
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                EmptyStateView(
                    title: "就这条新闻问点什么",
                    message: capabilityNote,
                    systemImage: "bubble.left.and.bubble.right"
                )
                suggestionChips
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .background(Theme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { composer }
    }

    /// 照实说明现在这个模型手里有什么 —— 尤其要讲清 OpenAI 兼容协议**不能联网**，
    /// 否则用户会以为它没搜到是「新闻没有后续」。
    private var capabilityNote: String {
        guard let config = AppSettings.currentAIChatConfig() else {
            return "还没配好 AI 接口，请到「设置 → AI 对话」填写地址与模型。"
        }
        guard !config.apiKey.isEmpty else {
            return "还没填 API Key，请到「设置 → AI 对话」填写。"
        }
        return "它已经看过这条的摘要与报道时间线；需要时会自己去联网搜索，或去读原文。"
    }

    private var suggestionChips: some View {
        VStack(spacing: 8) {
            ForEach(Self.suggestions, id: \.self) { text in
                Button {
                    model.input = text
                } label: {
                    Text(text)
                        .font(Typography.meta)
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.surface))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 对话

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { message in
                        bubble(message).id(message.id)
                    }

                    if let status = model.statusText {
                        statusRow(status)
                    }

                    if let notice = model.notice {
                        NoticeBanner(notice: HotTopicsStore.Notice(kind: .failed, message: notice))
                    }

                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, 12)
            }
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { composer }
            // 只用单参数形式：双参数 .onChange 在 iOS 16 上是硬错误
            .onChange(of: model.scrollTick) { _ in
                // 在视图更新期间同步调 scrollTo 会「修改状态」，异步跳一下最稳
                DispatchQueue.main.async {
                    withAnimation(.linear(duration: 0.12)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: AIChatMessage) -> some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 44) }

            Group {
                if message.text.isEmpty && message.isStreaming {
                    Text("…")
                        .font(Typography.body)
                        .foregroundColor(Theme.textTertiary)
                } else {
                    Text(rendered(message))
                        .font(Typography.body)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .fill(message.role == .user ? Theme.surfaceElevated : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )

            if message.role == .assistant { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// 流式过程中按纯文本渲染，一轮结束后才解析 Markdown ——
    /// 每来一个字就解析一次 Markdown 太贵。
    private func rendered(_ message: AIChatMessage) -> AttributedString {
        guard message.role == .assistant, !message.isStreaming else {
            return AttributedString(message.text)
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: message.text, options: options))
            ?? AttributedString(message.text)
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7)
            Text(text)
                .font(Typography.meta)
                .foregroundColor(Theme.textTertiary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 8) {
                TextField("就这条新闻问点什么…", text: $model.input)
                    .font(Typography.body)
                    .foregroundColor(Theme.textPrimary)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )

                if model.isStreaming {
                    Button(action: model.stop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(Theme.breakout)
                    }
                    .accessibilityLabel("停止")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(model.canSend ? Theme.accent : Theme.textTertiary)
                    }
                    .disabled(!model.canSend)
                    .accessibilityLabel("发送")
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 8)
        }
        .background(Theme.surface)
    }

    private func send() {
        model.send(item: item, story: story, prefetchedDigest: prefetchedDigest)
    }
}
