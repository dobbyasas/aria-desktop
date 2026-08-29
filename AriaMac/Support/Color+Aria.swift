import SwiftUI

extension Color {
    static let ariaBackground = Color(red: 0.051, green: 0.059, blue: 0.071)
    static let ariaSurface = Color(red: 0.082, green: 0.094, blue: 0.110)
    static let ariaPanel = Color(red: 0.102, green: 0.114, blue: 0.133)
    static let ariaPanelRaised = Color(red: 0.125, green: 0.141, blue: 0.165)
    static let ariaDivider = Color.white.opacity(0.085)
    static let ariaTextPrimary = Color(red: 0.94, green: 0.96, blue: 0.98)
    static let ariaTextSecondary = Color(red: 0.61, green: 0.65, blue: 0.70)
    static let ariaAccent = Color(red: 0.24, green: 0.86, blue: 0.78)
    static let ariaAccentMuted = Color(red: 0.11, green: 0.38, blue: 0.49)

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
