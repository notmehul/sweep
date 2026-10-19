import AppKit
import SweepCore
import SwiftUI

/// Design tokens. Every colour has a light and a dark value and follows the system setting.
/// Direction: "instrument, but clean" — graphite surfaces, one mint accent, light numerals.
enum Theme {
    static let background = dynamic(light: 0xF6F6F7, dark: 0x111214)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x18191C)
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x1F2024)
    static let hairline = dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.08)
    static let text = dynamic(light: 0x16171A, dark: 0xF2F2F3)
    static let secondary = dynamic(light: 0x5B5F66, dark: 0xA3A6AC)
    static let track = dynamic(light: 0xE7E8EB, dark: 0x25272B)
    static let trackDeep = dynamic(light: 0xDADCE0, dark: 0x2D2F34)

    /// Accent doubles as the "rebuilds itself" colour; the light value keeps 4.5:1 on white.
    static let accent = dynamic(light: 0x16805A, dark: 0x6FD8A8)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0E1A14)
    static let review = dynamic(light: 0xA86A0C, dark: 0xE8B04B)
    static let yours = dynamic(light: 0x667085, dark: 0x8C93A0)

    static func color(for bucket: Bucket) -> Color {
        switch bucket {
        case .rebuilds: accent
        case .review: review
        case .yours, .dontTouch: yours
        }
    }

    /// Icons pair with colour so the bucket never depends on colour alone.
    static func symbol(for bucket: Bucket) -> String {
        switch bucket {
        case .rebuilds: "arrow.triangle.2.circlepath"
        case .review: "shippingbox"
        case .yours, .dontTouch: "person"
        }
    }

    static func title(for bucket: Bucket) -> String {
        switch bucket {
        case .rebuilds: "Rebuilds itself"
        case .review: "Probably don't need"
        case .yours: "Your call"
        case .dontTouch: "Kept safe"
        }
    }

    static func blurb(for bucket: Bucket) -> String {
        switch bucket {
        case .rebuilds: "Caches and leftovers apps recreate"
        case .review: "Unused apps, installers, old downloads"
        case .yours: "Big files not opened in a year"
        case .dontTouch: "Sweep never offers these"
        }
    }

    // Type ramp. 13pt is the floor for anything meant to be read.
    static let display = Font.system(size: 64, weight: .light).monospacedDigit()
    static let displayUnit = Font.system(size: 24, weight: .light)
    static let title = Font.system(size: 22, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 13)
    static let number = Font.system(size: 13, weight: .medium).monospacedDigit()
    static let rowNumber = Font.system(size: 15, weight: .semibold).monospacedDigit()

    static let radius: CGFloat = 12
    static let gutter: CGFloat = 48

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum Format {
    /// "7.7 GB", "631 MB", "48 KB": one decimal only where it carries meaning.
    static func bytes(_ value: Int64) -> String {
        let v = Double(max(0, value))
        switch v {
        case 1e12...: return String(format: "%.1f TB", v / 1e12)
        case 1e11..<1e12: return String(format: "%.0f GB", v / 1e9)
        case 1e9..<1e11: return String(format: "%.1f GB", v / 1e9)
        case 1e6..<1e9: return String(format: "%.0f MB", v / 1e6)
        case 1e3..<1e6: return String(format: "%.0f KB", v / 1e3)
        default: return "\(Int(v)) bytes"
        }
    }

    /// Disk totals before/after a cleanup: two decimals, so a 64 MB change doesn't read as 1 GB.
    static func precise(_ value: Int64) -> String {
        let v = Double(max(0, value))
        return v >= 1e9 ? String(format: "%.2f GB", v / 1e9) : bytes(value)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Splits "38.4 GB" into ("38.4", "GB") for the large display numeral.
    static func bytesParts(_ value: Int64) -> (String, String) {
        let parts = bytes(value).split(separator: " ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : (parts.first ?? "0", "")
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func relative(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Never opened" }
        let days = Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 1 { return "Used today" }
        if days == 1 { return "Used yesterday" }
        if days < 45 { return "Used \(days) days ago" }
        return "Last used " + date.formatted(.dateTime.month(.abbreviated).year())
    }
}

/// Primary call to action: filled accent, one per screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 20)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Secondary action: quiet, text-weight, same hit height as the primary.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.hairline.opacity(configuration.isPressed ? 1 : 0)))
            .contentShape(Rectangle())
    }
}

/// Card surface: hairline ring instead of a heavy shadow.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// `@State` is a macro in the macOS 27 SDK and the Command Line Tools ship no SwiftUI macro
/// plugin. The property wrapper still exists; reaching it through an alias bypasses the macro.
typealias ViewState = SwiftUI.State
