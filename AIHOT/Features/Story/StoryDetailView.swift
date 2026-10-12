import Combine
import Foundation
import SwiftUI

@MainActor
final class StoryDetailModel: ObservableObject {

    @Published private(set) var story: Story?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var didLoad = false

    func load(publicId: String?) async {
        guard !didLoad, !isLoading else { return }

        guard let publicId = publicId else {
            didLoad = true
            errorMessage = "这条内容没有聚合详情，可在下方打开站内页面或原文查看。"
            return
        }

        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }

        do {
            let outcome = try await AIHOTAPI.shared.story(publicId: publicId)
            switch outcome {
            case .modified(let response):
                StoryCache.store(response.story)
                story = response.story
                errorMessage = nil

            case .notModified:
                // 304 说明本地这份就是最新的：正文从磁盘缓存里取回来，
                // 否则「第二次打开就没有报道时间线」。
                if let cached = StoryCache.story(for: publicId) {
                    story = cached
                    errorMessage = nil
                } else {
                    // ETag 还在但正文缓存被清掉了：绕开条件请求重取一次
                    let retry = try await AIHOTAPI.shared.story(publicId: publicId, ignoreCache: true)
                    if case .modified(let response) = retry {
                        StoryCache.store(response.story)
                        story = response.story
                        errorMessage = nil
                    } else {
                        errorMessage = "暂时取不到这条的报道时间线，稍后重进这个页面再试"
                    }
                }
            }
        } catch let error as APIError {
            // 离线/失败时，如果本地有缓存就照常显示，只加一句说明
            if let cached = StoryCache.story(for: publicId) {
                story = cached
                errorMessage = "网络不可用，显示的是上次缓存的内容"
            } else {
                errorMessage = error.message
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct StoryDetailView: View {

    let item: HotTopic
    let prefetchedDigest: String?

    @StateObject private var model = StoryDetailModel()
    @State private var safariURL: URL?

    private var publicId: String? {
        StoryID.publicId(fromStoryLink: item.links?.story)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleBlock

                if let story = model.story {
                    if !story.digestParagraphs.isEmpty {
                        SectionTitle(text: "AI 摘要")
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(story.digestParagraphs.indices, id: \.self) { index in
                                Text(story.digestParagraphs[index])
                                    .font(Typography.body)
                                    .foregroundColor(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .cardBackground()
                    }

                    if !story.sortedReports.isEmpty {
                        SectionTitle(text: "报道时间线")
                        VStack(spacing: 0) {
                            let reports = story.sortedReports
                            ForEach(reports.indices, id: \.self) { index in
                                ReportRow(report: reports[index]) { url in
                                    safariURL = url
                                }
                                if index < reports.count - 1 {
                                    Hairline().padding(.leading, 14)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                                .fill(Theme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                    }
                } else if let digest = prefetchedDigest, !digest.isEmpty {
                    SectionTitle(text: "AI 摘要")
                    Text(digest)
                        .font(Typography.body)
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .cardBackground()
                } else if model.isLoading {
                    ForEach(0..<2, id: \.self) { _ in SkeletonCard() }
                }

                // 提示条独立于上面的分支：有预取摘要时也要能看到
                // 「没有聚合详情 / 网络不可用 / 服务端报错」这类说明
                if let message = model.errorMessage {
                    NoticeBanner(notice: HotTopicsStore.Notice(kind: .failed, message: message))
                }

                actionButtons
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(publicId: publicId) }
        .safariSheet(url: $safariURL)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                RankNumber(rank: item.rank)
                if let status = model.story?.status, !status.isEmpty {
                    BadgeChip(text: statusText(status), color: Theme.accent)
                }
                Spacer(minLength: 0)
                Text(RelativeTime.relative(item.latestAt))
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
            }

            Text(model.story?.title ?? item.title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            let meta = metaLine
            if !meta.isEmpty {
                Text(meta)
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var metaLine: String {
        var parts: [String] = []

        if let story = model.story {
            if let sources = story.sourceCount, sources > 0 {
                parts.append("\(sources) 个来源")
            }
            if let reports = story.reportCount, reports > 0 {
                parts.append("\(reports) 篇报道")
            }
            if let first = story.firstReportAt {
                parts.append("首发 \(RelativeTime.absoluteShort(first))")
            }
            if let latest = story.latestAt {
                parts.append("最新 \(RelativeTime.relative(latest))")
            }
        } else {
            let summary = SourceSummary.make(for: item)
            if !summary.preview.isEmpty { parts.append(summary.preview) }
            if !summary.counts.isEmpty { parts.append(summary.counts) }
        }

        return parts.joined(separator: " · ")
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "active": return "进行中"
        case "closed", "archived": return "已归档"
        default: return status
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            if let link = item.links?.aihot ?? model.story?.links?.aihot, let url = URL(string: link) {
                LinkButton(title: "在 AIHOT 阅读全文", systemImage: "text.book.closed", url: url) { url in
                    safariURL = url
                }
            }
            if let link = item.links?.original, let url = URL(string: link) {
                LinkButton(title: "打开原文", systemImage: "arrow.up.right.square", url: url) { url in
                    safariURL = url
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct LinkButton: View {
    let title: String
    let systemImage: String
    let url: URL
    let action: (URL) -> Void

    var body: some View {
        Button {
            action(url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
            }
            .foregroundColor(Theme.accent)
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
    }
}

private struct ReportRow: View {
    let report: Report
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let name = report.source?.name, !name.isEmpty {
                    LetterAvatar(name: name, size: 16)
                    Text(LetterAvatar.displayName(from: name))
                        .font(Typography.meta)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(RelativeTime.relative(report.publishedAt))
                    .font(Typography.meta)
                    .foregroundColor(Theme.textTertiary)
            }

            Text(report.title ?? "")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = report.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                if let link = report.links?.original, let url = URL(string: link) {
                    Button("原文") { onOpen(url) }
                }
                if let link = report.links?.aihot, let url = URL(string: link) {
                    Button("站内页") { onOpen(url) }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.accent)
            .buttonStyle(.plain)
        }
        .padding(14)
    }
}
