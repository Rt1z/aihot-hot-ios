import SwiftUI
import UIKit

// MARK: - 徽章

struct BadgeChip: View {
    let text: String
    var color: Color = Theme.neutralBadge

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: Metrics.chipCorner, style: .continuous)
                    .fill(color.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.chipCorner, style: .continuous)
                    .stroke(color.opacity(0.35), lineWidth: 1)
            )
    }
}

// MARK: - 序号

struct RankNumber: View {
    let rank: Int
    var compact: Bool = false

    private var text: String {
        compact ? String(format: "%02d", rank) : String(format: "NO.%02d", rank)
    }

    var body: some View {
        Text(text)
            .font(compact ? Typography.rankSmall : Typography.rankBig)
            .foregroundColor(rank <= 3 ? Theme.accent : Theme.textSecondary)
            .monospacedDigit()
    }
}

// MARK: - 分隔线

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
    }
}

// MARK: - 分区标题

struct SectionTitle: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 3, height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            Text(text)
                .font(Typography.sectionTitle)
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

// MARK: - 字母头像

struct LetterAvatar: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Text(LetterAvatar.initial(from: name))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LetterAvatar.color(for: name)))
    }

    /// 「X：邵猛 (@shao__meng)」→「邵」；「IT之家·人工智能」→「I」
    static func initial(from name: String) -> String {
        var value = name
        if let range = value.range(of: "：") {
            let after = value[range.upperBound...]
            if !after.isEmpty {
                value = String(after)
            }
        }
        for scalar in value.unicodeScalars {
            let isCJK = scalar.value >= 0x4E00 && scalar.value <= 0x9FFF
            if isCJK || CharacterSet.alphanumerics.contains(scalar) {
                return String(Character(scalar)).uppercased()
            }
        }
        return "#"
    }

    static func color(for name: String) -> Color {
        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        let index = Int(hash % UInt64(Theme.avatarPalette.count))
        return Color(uiColor: UIColor(hex: Theme.avatarPalette[index]))
    }

    /// 「X：Andrej Karpathy (@karpathy)」→「Andrej Karpathy」
    static func displayName(from name: String) -> String {
        var value = name
        if let range = value.range(of: "：") {
            let after = value[range.upperBound...]
            if !after.isEmpty {
                value = String(after)
            }
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: " (") {
            value = String(value[value.startIndex..<range.lowerBound])
        }
        if let range = value.range(of: "（") {
            value = String(value[value.startIndex..<range.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 官网用来源头像堆叠表示「多来源」，这里用字母头像复刻同样的位置与语义。
struct AvatarStack: View {
    let names: [String]
    var overflowCount: Int = 0
    var maxVisible: Int = 5
    var size: CGFloat = 18

    private var uniqueNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let key = name.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    var body: some View {
        let unique = uniqueNames
        let visible = Array(unique.prefix(maxVisible))
        // 名字列表之外还有多少来源没展示出来
        let hidden = Swift.max(unique.count - visible.count, 0) + Swift.max(overflowCount - unique.count, 0)

        HStack(spacing: -size * 0.32) {
            ForEach(visible, id: \.self) { name in
                LetterAvatar(name: name, size: size)
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 1.5))
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(Theme.surfaceElevated))
                    .overlay(Circle().stroke(Theme.surface, lineWidth: 1.5))
            }
        }
    }
}

// MARK: - 来源说明行

struct SourceSummary {
    let preview: String
    let counts: String

    static func make(for item: HotTopic) -> SourceSummary {
        let names = (item.sourceNames ?? []).map { LetterAvatar.displayName(from: $0) }
        var preview: String
        switch names.count {
        case 0:
            preview = item.source?.name ?? ""
        case 1:
            preview = names[0]
        case 2:
            preview = "\(names[0])、\(names[1])"
        default:
            preview = "\(names[0])、\(names[1]) 等"
        }

        var parts: [String] = []
        if let sourceCount = item.sourceCount, sourceCount > 0 {
            parts.append("\(sourceCount) 个来源")
        }
        if let participants = item.participantCount, participants > 0 {
            parts.append("\(participants) 位参与者")
        }
        return SourceSummary(preview: preview, counts: parts.joined(separator: " · "))
    }
}

// MARK: - 提示条

struct NoticeBanner: View {
    let notice: HotTopicsStore.Notice

    private var color: Color {
        switch notice.kind {
        case .offline: return Theme.neutralBadge
        case .rateLimited: return Theme.accent
        case .failed: return Theme.breakout
        }
    }

    private var systemImage: String {
        switch notice.kind {
        case .offline: return "wifi.slash"
        case .rateLimited: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
            Text(notice.message)
                .font(Typography.meta)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
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

// MARK: - 骨架屏

struct SkeletonBlock: View {
    var height: CGFloat
    var widthFraction: CGFloat = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Theme.border)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: widthFraction, y: 1.0, anchor: .leading)
    }
}

struct SkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonBlock(height: 14, widthFraction: 0.3)
            SkeletonBlock(height: 18, widthFraction: 0.9)
            SkeletonBlock(height: 12, widthFraction: 0.95)
            SkeletonBlock(height: 12, widthFraction: 0.7)
        }
        .padding(14)
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
}

// MARK: - 空态

struct EmptyStateView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(Theme.textTertiary)
            Text(title)
                .font(Typography.rowTitle)
                .foregroundColor(Theme.textPrimary)
            Text(message)
                .font(Typography.meta)
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - 卡片容器修饰器

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
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
}

extension View {
    func cardBackground() -> some View {
        modifier(CardBackground())
    }
}
