import AppKit
import SwiftUI

enum UsageTheme {
    static let popoverSize = CGSize(width: 380, height: 440)
    static let pagePadding: CGFloat = 18
    static let background = UsageStyle.native.colors.background
}

enum UsageStyle: String, CaseIterable, Identifiable {
    case native
    case orbit

    static let storageKey = "interfaceStyle"

    var id: Self { self }

    var title: String {
        switch self {
        case .native: "A · 原生精修"
        case .orbit: "B · 环形仪表"
        }
    }

    var colors: UsageColors {
        switch self {
        case .native: .native
        case .orbit: .orbit
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

    // 与已确认的 A、B DEMO 共用色值，避免系统强调色和壁纸改变设计。
    static let native = UsageColors(
        background: adaptive(light: 0xf6f7f9, dark: 0x232428),
        surface: adaptive(light: 0xffffff, dark: 0x2d2e33),
        soft: adaptive(light: 0xeaeef4, dark: 0x363941),
        primaryText: adaptive(light: 0x252b35, dark: 0xf0f1f5),
        secondaryText: adaptive(light: 0x68717e, dark: 0xa8afbb),
        border: adaptive(light: 0xdce1e8, dark: 0x3f424b),
        accent: adaptive(light: 0x2868c7, dark: 0x81b2ff),
        tint: adaptive(light: 0xe6eefb, dark: 0x303e54)
    )

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
            .padding(1)
            .frame(
                width: UsageTheme.popoverSize.width,
                height: UsageTheme.popoverSize.height
            )
            .background(colors.background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(colors.border, lineWidth: 1)
            }
            .foregroundStyle(colors.primaryText)
            .environment(\.usageColors, colors)
            .tint(colors.accent)
    }
}

private struct UsageColorsKey: EnvironmentKey {
    static let defaultValue = UsageColors.native
}

extension EnvironmentValues {
    var usageColors: UsageColors {
        get { self[UsageColorsKey.self] }
        set { self[UsageColorsKey.self] = newValue }
    }
}
