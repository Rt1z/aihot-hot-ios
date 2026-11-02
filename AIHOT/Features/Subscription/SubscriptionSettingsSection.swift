import SwiftUI
import UIKit

/// 设置 → 订阅。两个地址是普通设置；Dajiala Key 走 Keychain（草稿 + 显式保存）。
///
/// 抽成一个返回 `Section` 的子视图，避免 `AboutView` 继续膨胀；`Form` 会把它
/// 当成一个正常的分组渲染。
struct SubscriptionSettingsSection: View {

    @ObservedObject var store: SubscriptionStore

    @AppStorage(AppSettings.subscriptionConfigURLKey) private var configURL: String = ""
    @AppStorage(AppSettings.subscriptionRSSHubBaseURLKey) private var rsshubURL: String = ""

    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var keyFellBack = false
    @State private var probe: ProbeState?
    @State private var showPaidConfirm = false
    @State private var showRawConfirm = false
    @State private var rawCaptureMessage: String?

    private enum ProbeState: Equatable {
        case running
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case .running: return "正在检查…"
            case .success(let text), .failure(let text): return text
            }
        }

        var isFailure: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("订阅配置地址")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                TextField("http://MacBook.local:8088/subscriptions.json", text: $configURL)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("RSSHub 地址")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                TextField("http://MacBook.local:1200", text: $rsshubURL)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Dajiala Key")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                SecureField("只用于公众号抓取，按次计费", text: $keyDraft)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .onChange(of: keyDraft) { _ in
                        keySaved = false
                    }
            }

            Button(action: saveKey) {
                Label(keySaved ? "已保存密钥" : "保存 Dajiala 密钥", systemImage: "key")
            }
            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                run { await store.checkConfig() }
            } label: {
                Label("检查订阅配置", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(probe == .running)

            Button {
                run { await store.testRSSHub() }
            } label: {
                Label("测试 RSSHub", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(probe == .running)

            Button {
                showPaidConfirm = true
            } label: {
                Label("试抓第一个公众号（约 ¥0.06）", systemImage: "creditcard")
            }
            .disabled(probe == .running)

            // 真实响应结构只有拿到字节才能确认；这个按钮把响应（脱敏 Key、截断 2 万字符）
            // 复制到剪贴板，用于替换测试夹具。正式使用不需要点它。
            Button {
                showRawConfirm = true
            } label: {
                Label("复制公众号原始响应（调试用，约 ¥0.06）", systemImage: "doc.on.doc")
            }
            .disabled(probe == .running)

            if let probe = probe {
                Text(probe.message)
                    .font(.system(size: 12))
                    .foregroundColor(probe.isFailure ? Theme.breakout : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let rawCaptureMessage = rawCaptureMessage {
                Text(rawCaptureMessage)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("订阅")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("公众号接口按次计费（约 ¥0.06/次）。自动刷新每个公众号最多每 6 小时一次，只取第 1 页；下拉手动刷新会重新抓取全部启用的公众号。")
                Text("B 站走你自己电脑上的 RSSHub，免费，自动刷新最多每 10 分钟一次。")
                Text("订阅内容按标题与摘要里的关键词归入 科技 / 健康 / 成长 / 职业 / 周边；没有命中关键词的内容会归到「周边」。")
                Text("配置文件与 RSSHub 只在你的局域网内访问；配置文件里不要放任何 Key。地址建议填电脑的本机名（例如 MacBook.local），裸 IP 在较新的 iOS 上可能被系统拦。")
                Text("密钥存在系统钥匙串，只保存在本机。")
                if keyFellBack {
                    Text("注意：这台设备上钥匙串不可用，Dajiala Key 已改用应用内存储（仅本机、卸载即丢失）。")
                        .foregroundColor(Theme.breakout)
                }
            }
        }
        .task { loadKey() }
        .confirmationDialog(
            "试抓会真实调用一次 Dajiala（约 ¥0.06），且不会写入订阅列表。",
            isPresented: $showPaidConfirm,
            titleVisibility: .visible
        ) {
            Button("继续试抓") {
                run { await store.testWeChat() }
            }
            Button("取消", role: .cancel) { }
        }
        .confirmationDialog(
            "抓原始响应会真实调用一次 Dajiala（约 ¥0.06），并把脱敏后的响应复制到剪贴板。",
            isPresented: $showRawConfirm,
            titleVisibility: .visible
        ) {
            Button("继续并复制") {
                guard probe != .running else { return }
                probe = .running
                Task {
                    let result = await store.captureWeChatRaw()
                    probe = nil
                    if result.success {
                        UIPasteboard.general.string = result.text
                        rawCaptureMessage = "已复制原始响应（\(result.text.count) 字符），可直接粘贴给开发者替换夹具。"
                    } else {
                        rawCaptureMessage = result.text
                    }
                }
            }
            Button("取消", role: .cancel) { }
        }
    }

    private func loadKey() {
        keyDraft = AIChatSecretStore.shared.dajialaKey()
        keyFellBack = AIChatSecretStore.shared.isUsingDajialaFallback()
        keySaved = false
    }

    private func saveKey() {
        let stored = AIChatSecretStore.shared.setDajialaKey(keyDraft)
        keyFellBack = !stored && !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        keySaved = true
    }

    private func run(_ operation: @escaping () async -> SubscriptionStore.Probe) {
        guard probe != .running else { return }
        probe = .running
        Task {
            let result = await operation()
            probe = result.success ? .success(result.message) : .failure(result.message)
        }
    }
}
