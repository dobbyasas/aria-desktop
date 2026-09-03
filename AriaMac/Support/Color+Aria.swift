import SwiftUI

extension Color {
    static let ariaBackground = Color(hex: "#11110F")
    static let ariaSurface = Color(hex: "#1A1916")
    static let ariaPanel = Color(hex: "#151412")
    static let ariaSidebarBackground = Color(red: 0.102, green: 0.114, blue: 0.133)
    static let ariaPanelRaised = Color(hex: "#24221E")
    static let ariaDivider = Color.white.opacity(0.09)
    static let ariaTextPrimary = Color(hex: "#F3F0E8")
    static let ariaTextSecondary = Color(hex: "#A8A39A")
    static let ariaAccent = Color(hex: "#FF6B4A")
    static let ariaAccentMuted = Color(hex: "#4B2A22")
    static let ariaViolet = Color(hex: "#8E829D")
    static let ariaWarm = Color(hex: "#DFA45A")
    static let ariaCyan = Color(hex: "#7A9E9F")

    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        self.init(red: red, green: green, blue: blue)
    }
}
