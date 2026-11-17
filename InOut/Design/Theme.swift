import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8) & 0xFF) / 255.0
        let blue = CGFloat(hex & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}

/// 站点色系（暗色为主，浅色跟随）。想整体换色只改这一个文件。
enum Theme {

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    // 背景 / 容器
    static let background = dynamic(dark: 0x0A0A0B, light: 0xFFFFFF)
    static let surface = dynamic(dark: 0x141416, light: 0xF7F7F8)
    static let surfaceElevated = dynamic(dark: 0x1B1B1F, light: 0xFFFFFF)
    static let border = dynamic(dark: 0x232327, light: 0xE5E5EA)

    // 文字
    static let textPrimary = dynamic(dark: 0xF2F2F3, light: 0x111113)
    static let textSecondary = dynamic(dark: 0x9B9BA3, light: 0x5F5F67)
    static let textTertiary = dynamic(dark: 0x6C6C74, light: 0x8E8E93)

    // 语义色
    static let accent = dynamic(dark: 0xFF6A2B, light: 0xE2541F)
    static let breakout = dynamic(dark: 0xFF3B30, light: 0xD70015)
    static let up = dynamic(dark: 0xFF6A2B, light: 0xE2541F)
    static let down = dynamic(dark: 0x34C759, light: 0x248A3D)
    static let neutralBadge = dynamic(dark: 0x8E8E93, light: 0x6B6B73)
    static let newBadge = dynamic(dark: 0x0A84FF, light: 0x0071E3)
    static let warningBackground = dynamic(dark: 0x2A1B10, light: 0xFFF3E8)

    /// 字母头像调色板
    static let avatarPalette: [UInt32] = [
        0xE2541F, 0x0A84FF, 0x34C759, 0xAF52DE,
        0xFFB300, 0xFF3B30, 0x5AC8FA, 0x8E8E93
    ]
}

enum Metrics {
    static let cardCorner: CGFloat = 14
    static let chipCorner: CGFloat = 6
    static let horizontalPadding: CGFloat = 16
    static let cardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 18
}

enum Typography {
    static let rankBig = Font.system(size: 16, weight: .heavy, design: .monospaced)
    static let rankSmall = Font.system(size: 13, weight: .bold, design: .monospaced)
    static let cardTitle = Font.system(size: 18, weight: .semibold)
    static let rowTitle = Font.system(size: 16, weight: .medium)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 14)
    static let meta = Font.system(size: 12)
    static let heat = Font.system(size: 24, weight: .bold, design: .rounded)
    static let heatSmall = Font.system(size: 16, weight: .bold, design: .rounded)
    /// 回答里的 Markdown 标题（body 是 14）：h1/h2 大一号，h3 起只加粗不再放大
    static func markdownHeading(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .bold)
        case 2: return .system(size: 17, weight: .semibold)
        case 3: return .system(size: 15, weight: .semibold)
        default: return .system(size: 14, weight: .semibold)
        }
    }
    /// 回答里代码块的等宽字体
    static let markdownCode = Font.system(size: 13, design: .monospaced)
    /// 顶栏图标（详情页「对话/收藏」、对话弹窗「清空」）：不设字号时 toolbar 按
    /// 正文 17pt 渲染 SF Symbol，这里取其 4/5 —— Symbol 随字号线性缩放，高宽同比缩小
    static let toolbarIcon = Font.system(size: 13.6)
}
