import AppKit
import SwiftUI

enum UsageTheme {
    static let popoverSize = CGSize(width: 360, height: 440)
    static let pagePadding: CGFloat = 18
    static let background = UsageStyle.aurora.colors.background
}

enum UsageStyle: String, CaseIterable, Identifiable {
    case orbit
    case neon
    case aurora

    static let storageKey = "interfaceStyle"

    var id: Self { self }

    var hasAccentCards: Bool { self == .neon || self == .aurora }

    var title: String {
        switch self {
        case .orbit: "环形仪表"
        case .neon: "霓光仪表"
        case .aurora: "极光卡片"
        }
    }

    var colors: UsageColors {
        switch self {
        case .orbit: .orbit
        case .neon: .neon
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
    var accentEnd: Color? = nil
    var accentMiddle: Color? = nil
    var accentText: Color? = nil

    var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentMiddle ?? accent, accentEnd ?? accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

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

    static let neon = UsageColors(
        background: adaptive(light: 0xf0f3fc, dark: 0x0f1829),
        surface: adaptive(light: 0xffffff, dark: 0x111b2c),
        soft: adaptive(light: 0xdce2f0, dark: 0x354255),
        primaryText: adaptive(light: 0x202c45, dark: 0xf6f8ff),
        secondaryText: adaptive(light: 0x596982, dark: 0xb9c8e2),
        border: adaptive(light: 0xc4cee5, dark: 0x39516c),
        accent: adaptive(light: 0x087f9b, dark: 0x24dfff),
        tint: adaptive(light: 0xe0e8fb, dark: 0x273160),
        accentEnd: adaptive(light: 0x8454cc, dark: 0xb46aff),
        accentMiddle: adaptive(light: 0x4662cc, dark: 0x4d6bff),
        accentText: adaptive(light: 0x087f9b, dark: 0x91f3ff)
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
            colors.accentEnd = warning
            colors.accentMiddle = warning
            colors.accentText = warning
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
            .padding(1)
            .frame(
                width: UsageTheme.popoverSize.width,
                height: UsageTheme.popoverSize.height
            )
            .background {
                colors.background
                if style.hasAccentCards {
                    RadialGradient(
                        colors: [colors.tint.opacity(style == .neon ? 0.45 : 0.12), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 390
                    )
                    RadialGradient(
                        colors: [colors.accent.opacity(style == .neon ? 0.09 : 0.035), .clear],
                        center: .bottomLeading,
                        startRadius: 0,
                        endRadius: 260
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: style.hasAccentCards ? 20 : 16))
            .overlay {
                if style == .neon {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            LinearGradient(
                                colors: [colors.accentMiddle ?? colors.accent, colors.accentEnd ?? colors.accent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 17)
                                .inset(by: 3)
                                .strokeBorder(colors.accentGradient, lineWidth: 0.7)
                                .opacity(0.45)
                        }
                } else {
                    RoundedRectangle(cornerRadius: style.hasAccentCards ? 20 : 16)
                        .strokeBorder(colors.border, lineWidth: 1)
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
