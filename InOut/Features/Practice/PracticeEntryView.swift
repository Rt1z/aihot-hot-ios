import SwiftUI

/// 一条练习记录的回看页（只读）。
///
/// 顺序刻意是「先看你写的，再看原文」：回看时最该发生的是回忆与自我核对，
/// 原文默认收起，想看再展开。历史不在这里编辑 —— 要改就「再练一次」生成新记录。
struct PracticeEntryView: View {

    let store: PracticeStore
    let entry: PracticeEntry

    @State private var showPractice = false
    @State private var showOriginal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                SectionTitle(text: "你写的")
                PracticeSummaryView(entry: entry)
                    .cardBackground()

                if let note = PracticeText.clean(entry.selfNote) {
                    SectionTitle(text: "自评")
                    Text(note)
                        .font(Typography.body)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                }

                if let review = entry.review {
                    SectionTitle(text: "AI 点评")
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownBlocksView(text: review.text)
                        Text("基于\(review.basis) · \(review.model)")
                            .font(Typography.meta)
                            .foregroundColor(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground()
                }

                if entry.article.kind == .savedLink {
                    if PracticeText.clean(entry.bodyText) != nil {
                        SectionTitle(text: "原文")
                        originalCard
                    }
                } else {
                    SectionTitle(text: "原文导读")
                    originalCard
                }

                Button {
                    showPractice = true
                } label: {
                    Label("再练一次", systemImage: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
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
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("回看")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPractice) {
            // 导入文章当时的正文已经随记录保存下来了；热点/周报条目没有 bodyText，
            // 基准按各自的导读/正文走。
            PracticeSheet(
                article: entry.article,
                articleText: entry.bodyText,
                store: store
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.article.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(RelativeTime.absoluteShort(entry.createdAt))
                Text(entry.mode.title)
                Text("\(entry.wordCount) 字")
                Spacer(minLength: 0)
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)
        }
    }

    private var originalCard: some View {
        DisclosureGroup(isExpanded: $showOriginal) {
            Text(originalText)
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } label: {
            Text(originalLabel)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.accent)
        }
        .cardBackground()
    }

    private var originalText: String {
        if entry.article.kind == .savedLink {
            return PracticeText.clean(entry.bodyText) ?? "练习时没有保存原文。"
        }
        return PracticeText.clean(entry.article.digest) ?? "练习时这篇没有可用的导读。"
    }

    private var originalLabel: String {
        if entry.article.kind == .savedLink, let body = PracticeText.clean(entry.bodyText) {
            return "展开练习时的原文（\(PracticeText.wordCount(body)) 字）"
        }
        return "展开练习时的导读"
    }
}
