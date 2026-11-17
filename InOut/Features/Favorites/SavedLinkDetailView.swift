import SwiftUI
import UIKit

/// 一条外部链接的阅读页。
///
/// 正文用内嵌 WKWebView 直接打开原文页面：公众号对普通请求会返回验证页，
/// 只有真正的浏览器能拿到全文；内嵌渲染也最接近原样式。系统阅读器
/// （`SFSafariViewController`）仍留在菜单里，作为「阅读器 / 网页版」逃生口。
///
/// 页面加载完成后会顺手做三件事：
/// 1. 把真实标题读回来（仅当当前标题还是兜底值，不覆盖用户手改的标题）；
/// 2. 抽出正文纯文本，供 AI 对话与「练一练」使用；
/// 3. 对公众号页面藏掉站点的顶栏/底栏与二维码，正文保持原样式。
struct SavedLinkDetailView: View {

    let link: SavedLink
    let favoritedAt: Date
    @ObservedObject var favorites: FavoritesStore
    let practice: PracticeStore

    @Environment(\.dismiss) private var dismiss

    @StateObject private var web = ArticleWebModel()
    @State private var webLink: WebLinkSheet?
    @State private var showChat = false
    @State private var showPractice = false
    @State private var showRename = false
    @State private var titleDraft = ""
    @State private var confirmRemove = false
    @State private var copied = false

    /// 标题可能被异步抓取或手动改过：始终从 store 里取当前那份。
    private var current: SavedLink {
        favorites.items
            .compactMap { $0.kind == .link ? $0.link : nil }
            .first { $0.url == link.url } ?? link
    }

    private var url: URL? { URL(string: current.url) }

    private var practiceArticle: PracticeArticle {
        PracticeArticle(
            kind: .savedLink,
            articleID: current.url,
            title: current.title,
            sourceName: current.host,
            originalURL: current.url,
            aihotURL: nil,
            digest: nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if web.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.vertical, 3)
            }

            ZStack {
                ArticleWebView(model: web)

                if let error = web.errorMessage {
                    errorOverlay(error)
                }
            }
            // 铺到屏幕底部：WebView 不再在 Tab 栏上方留一条与正文不同色的底
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showChat = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(Typography.toolbarIcon)
                        .foregroundColor(Theme.accent)
                }
                .accessibilityLabel("AI 对话")

                Button {
                    showPractice = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(Typography.toolbarIcon)
                        .foregroundColor(web.articleText == nil ? Theme.textTertiary : Theme.accent)
                }
                .disabled(web.articleText == nil)
                .accessibilityLabel("练一练")

                menu
            }
        }
        .task {
            if let url { web.load(url) }
        }
        .onChange(of: web.pageTitle) { title in
            guard let title = SharedLinkURL.cleanedTitle(title) else { return }
            // 只在标题还是兜底值（域名/「微信公众号文章」）时自动更新；
            // 用户手改过的标题不被网页标题覆盖。
            guard current.title == SharedLinkURL.defaultTitle(for: current.url),
                  title != current.title
            else { return }
            favorites.updateLinkTitle(url: current.url, title: title)
        }
        .sheet(isPresented: $showChat) {
            AIChatView(subject: .savedLink(link: current, articleText: web.articleText))
        }
        .sheet(isPresented: $showPractice) {
            PracticeSheet(article: practiceArticle, articleText: web.articleText, store: practice)
        }
        .webLinkSheet(item: $webLink)
        .alert("编辑标题", isPresented: $showRename) {
            TextField("标题", text: $titleDraft)
            Button("保存") {
                favorites.updateLinkTitle(url: current.url, title: titleDraft)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("留空会用域名兜底。")
        }
        .confirmationDialog(
            "从收藏里移除这条链接？",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                favorites.remove(linkURL: current.url)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(current.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if current.isWeChatArticle {
                    // 公众号文章不必再挂域名
                    BadgeChip(text: current.sourceLabel, color: Theme.accent)
                } else {
                    Text(current.sourceLine)
                }
                Text("·")
                Text(RelativeTime.absoluteShort(favoritedAt))
                if copied {
                    Text("· 已复制")
                        .foregroundColor(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .font(Typography.meta)
            .foregroundColor(Theme.textTertiary)

            if web.requiresVerification {
                Text("微信要求先完成页面内的验证；验证后正文会自动加载。")
                    .font(Typography.meta)
                    .foregroundColor(Theme.breakout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("内容版权归原站点及作者所有，本 App 仅供个人使用。")
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    private var menu: some View {
        Menu {
            Button {
                web.reload()
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
            }

            if let url {
                Button {
                    webLink = WebLinkSheet(url: url, entersReader: true)
                } label: {
                    Label("在阅读器打开", systemImage: "text.book.closed")
                }
                Button {
                    webLink = WebLinkSheet(url: url)
                } label: {
                    Label("在 Safari 打开", systemImage: "safari")
                }
            }

            Button {
                UIPasteboard.general.string = current.url
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "已复制链接" : "复制链接", systemImage: "doc.on.doc")
            }

            Button {
                titleDraft = current.title
                showRename = true
            } label: {
                Label("编辑标题", systemImage: "pencil")
            }

            Divider()

            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Label("从收藏里移除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Typography.toolbarIcon)
                .foregroundColor(Theme.accent)
        }
        .accessibilityLabel("更多操作")
    }

    // MARK: - 失败态

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(Theme.textTertiary)
            Text("文章没有加载出来")
                .font(Typography.rowTitle)
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(Typography.meta)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            HStack(spacing: 16) {
                Button("重试") { web.reload() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.accent)
                if let url {
                    Button("在 Safari 打开") {
                        webLink = WebLinkSheet(url: url)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.accent)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .padding(24)
    }
}
