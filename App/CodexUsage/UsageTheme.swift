import AppKit
import SwiftUI

enum UsageTheme {
    static let popoverSize = CGSize(width: 380, height: 440)
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 18
    static let rowSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 10
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let accentBlue = accent
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
}
