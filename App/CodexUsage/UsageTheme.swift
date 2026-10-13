import AppKit
import SwiftUI

enum UsageTheme {
    static let popoverSize = CGSize(width: 360, height: 440)
    static let pagePadding: CGFloat = 18
    static let background = UsageStyle.aurora.colors.background
}

enum UsageStyle: String, CaseIterable, Identifiable {
    case orbit
    case aurora

    static let storageKey = "interfaceStyle"

    var id: Self { self }

    var hasAccentCards: Bool { self == .aurora }

    var title: String {
        switch self {
        case .orbit: "环形仪表"
        case .aurora: "极光卡片"
        }
    }

    var colors: UsageColors {
        switch self {
        case .orbit: .orbit
        case .aurora: .aurora
        }
    }
}

struct UsageColors {
    let background: Color
    let surface: Color
    let soft: Color
    let primaryText: Color
    let secondaryText: Color
    let border: Color
    var accent: Color
    var tint: Color
    let good = UsageColors.adaptive(light: 0x28775e, dark: 0x80c7ab)
    let warning = UsageColors.adaptive(light: 0x9b5a18, dark: 0xeaba7d)
    let warningTint = UsageColors.adaptive(light: 0xf8ebdc, dark: 0x473928)
    let danger = Color(nsColor: .systemRed)

    static let orbit = UsageColors(
        background: adaptive(light: 0xf5f4f8, dark: 0x222127),
        surface: adaptive(light: 0xffffff, dark: 0x2e2c35),
        soft: adaptive(light: 0xe9e5ef, dark: 0x3c3845),
        primaryText: adaptive(light: 0x302a3c, dark: 0xf2eff7),
        secondaryText: adaptive(light: 0x766c83, dark: 0xb2a9c1),
        border: adaptive(light: 0xe1dce9, dark: 0x403b49),
        accent: adaptive(light: 0x7952b8, dark: 0xbb9de9),
        tint: adaptive(light: 0xeee5fa, dark: 0x453754)
    )

    static let aurora = UsageColors(
        background: adaptive(light: 0xf0f6f3, dark: 0x142124),
        surface: adaptive(light: 0xffffff, dark: 0x1e2b2e),
        soft: adaptive(light: 0xd5e6df, dark: 0x40605e),
        primaryText: adaptive(light: 0x203c33, dark: 0xf5fafb),
        secondaryText: adaptive(light: 0x526f64, dark: 0xc1d0d2),
        border: adaptive(light: 0xc9ddd3, dark: 0x34494a),
        accent: adaptive(light: 0x19704f, dark: 0x94facb),
        tint: adaptive(light: 0xd4eee1, dark: 0x296657)
    )

    func withLowQuota(_ isLow: Bool) -> Self {
        var colors = self
        if isLow {
            colors.accent = warning
            colors.tint = warningTint
        }
        return colors
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1
            )
        })
    }
}

struct UsagePopoverSurface: ViewModifier {
    let style: UsageStyle
    var isLowQuota = false

    private var colors: UsageColors { style.colors.withLowQuota(isLowQuota) }

    func body(content: Content) -> some View {
        content
            .frame(
                width: UsageTheme.popoverSize.width,
                height: UsageTheme.popoverSize.height
            )
            // 圆角和外沿交给系统窗口，避免自绘圆角露出宿主底色形成双层边框。
            .background {
                colors.background
                if style.hasAccentCards {
                    RadialGradient(
                        colors: [colors.tint.opacity(0.12), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 390
                    )
                    RadialGradient(
                        colors: [colors.accent.opacity(0.035), .clear],
                        center: .bottomLeading,
                        startRadius: 0,
                        endRadius: 260
                    )
                }
            }
            .foregroundStyle(colors.primaryText)
            .environment(\.usageColors, colors)
            .tint(colors.accent)
    }
}

private struct UsageColorsKey: EnvironmentKey {
    static let defaultValue = UsageColors.aurora
}

extension EnvironmentValues {
    var usageColors: UsageColors {
        get { self[UsageColorsKey.self] }
        set { self[UsageColorsKey.self] = newValue }
    }
}
