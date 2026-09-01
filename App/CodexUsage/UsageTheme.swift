import SwiftUI

enum UsageTheme {
    static let popoverSize = CGSize(width: 410, height: 440)
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 10
    static let transitionDuration = 0.22

    static let background = Color(red: 0.055, green: 0.059, blue: 0.075)
    static let surface = Color.white.opacity(0.045)
    static let border = Color.white.opacity(0.09)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let accent = Color(red: 0.46, green: 0.41, blue: 1.0)
    static let accentBlue = Color(red: 0.23, green: 0.58, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.67, blue: 0.28)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.42)
}
