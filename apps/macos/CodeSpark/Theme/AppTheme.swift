import SwiftUI

enum AppTheme {
    // Sidebar: distinctly lighter than terminal
    static let sidebarBackground = Color(nsColor: .init(red: 0.22, green: 0.22, blue: 0.26, alpha: 1))
    static let toolbarBackground = Color(nsColor: .init(red: 0.15, green: 0.15, blue: 0.18, alpha: 1))
    // Terminal surface: noticeably lighter than sidebar
    static let surfaceBackground = Color(nsColor: .init(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    static let divider = Color.white.opacity(0.10)
    static let cardBackground = Color.white.opacity(0.06)
    // Blue accent
    static let accent = Color(nsColor: .init(red: 0.35, green: 0.55, blue: 0.85, alpha: 1))
    static let accentSubtle = Color(nsColor: .init(red: 0.15, green: 0.25, blue: 0.45, alpha: 0.50))
    static let statusRunning = Color.green
    static let statusIdle = Color.gray
    static let statusNeedsInput = Color.orange
    static let infoText = Color.white.opacity(0.50)
    static let sidebarItemBackground = Color.white.opacity(0.04)
}
