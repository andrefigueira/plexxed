import SwiftUI

/// The whole palette. Solid colours only.
enum Theme {
    static let background = Color(hex: 0x0E0F11)
    static let surface = Color(hex: 0x1A1C1F)
    static let surfaceHover = Color(hex: 0x24272B)
    static let textPrimary = Color(hex: 0xEDEDEA)
    static let textSecondary = Color(hex: 0x9C9FA5)
    static let track = Color(hex: 0x3A3D42)
    /// The one accent: the primary action and progress.
    static let accent = Color(hex: 0xEDEDEA)
    static let onAccent = Color(hex: 0x0E0F11)

    static let radius: CGFloat = 8
    static let gutter: CGFloat = 40
}

/// Four sizes, used everywhere.
extension Font {
    static let hero = Font.system(size: 34, weight: .bold)
    static let heading = Font.system(size: 20, weight: .semibold)
    static let body13 = Font.system(size: 13)
    static let body13Strong = Font.system(size: 13, weight: .semibold)
    static let caption11 = Font.system(size: 11)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Eases out without overshoot. Falls back to no motion when Reduce Motion is on.
extension Animation {
    static let quick = Animation.easeOut(duration: 0.18)
    static let calm = Animation.easeOut(duration: 0.3)
}
