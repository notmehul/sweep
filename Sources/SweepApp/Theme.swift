import AppKit
import SweepCore
import SwiftUI

/// Design tokens. Every colour has a light and a dark value and follows the system setting.
/// Direction: "aurora on glass". The window is translucent like the user's terminal (black at
/// ~55% over a blur of the desktop), an aurora drifts behind the content, and every surface
/// and button is native Liquid Glass. Colours come from the Ghostty palette.
enum Theme {
    /// Tint laid over the blurred desktop, like Ghostty's background-opacity.
    static let windowTint = dynamic(light: 0xFFFFFF, lightAlpha: 0.42, dark: 0x000000, darkAlpha: 0.55)
    /// Opaque-enough fill for places that need one (sheets, pinned headers).
    static let background = dynamic(light: 0xF4F4F6, lightAlpha: 0.85, dark: 0x0B0B0D, darkAlpha: 0.72)
    static let hairline = dynamic(light: 0x000000, lightAlpha: 0.08, dark: 0xFFFFFF, darkAlpha: 0.10)
    static let text = dynamic(light: 0x111214, dark: 0xFFFFFF)
    static let secondary = dynamic(light: 0x000000, lightAlpha: 0.58, dark: 0xFFFFFF, darkAlpha: 0.64)
    /// Empty, not-yet-scanned space: barely there.
    static let track = dynamic(light: 0x000000, lightAlpha: 0.05, dark: 0xFFFFFF, darkAlpha: 0.05)
    static let trackDeep = dynamic(light: 0x000000, lightAlpha: 0.09, dark: 0xFFFFFF, darkAlpha: 0.09)
    /// Scanned folders with nothing to clean: frosted, clearly above the track.
    static let segment = dynamic(light: 0x000000, lightAlpha: 0.13, dark: 0xFFFFFF, darkAlpha: 0.15)
    static let segmentDeep = dynamic(light: 0x000000, lightAlpha: 0.18, dark: 0xFFFFFF, darkAlpha: 0.21)

    /// Aurora green; doubles as the "rebuilds itself" colour.
    static let accent = dynamic(light: 0x0F8A5C, dark: 0x5BE3A6)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x04170F)
    /// Ghostty gold (palette 11) for "probably don't need".
    static let review = dynamic(light: 0x9A6400, dark: 0xF0B84A)
    /// Ghostty violet (palette 10) for "your call".
    static let yours = dynamic(light: 0x6B4FB0, dark: 0xA98BE0)

    /// Aurora ribbons: green, teal, violet, pink, blue (Ghostty palette 2, 6, 10, 13, 12).
    static let aurora: [Color] = [
        Color(red: 0.25, green: 0.88, blue: 0.62), Color(red: 0.17, green: 0.77, blue: 0.85),
        Color(red: 0.60, green: 0.47, blue: 0.81), Color(red: 0.92, green: 0.46, blue: 0.80),
        Color(red: 0.30, green: 0.60, blue: 1.00),
    ]

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

    static let radius: CGFloat = 20
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

    static func cleanupDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "d MMM, h:mm a"
        return formatter.string(from: date)
    }

    static func ago(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "Never" }
        let days = max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        return "\(days) days ago"
    }
}

extension View {
    /// The one primary action per screen: prominent Liquid Glass tinted aurora green.
    func primaryButton() -> some View {
        buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .foregroundStyle(Theme.onAccent)
            .font(.system(size: 14, weight: .semibold))
            .controlSize(.large)
    }

    /// Secondary actions: clear Liquid Glass, same height as the primary.
    func quietButton() -> some View {
        buttonStyle(.glass)
            .font(.system(size: 14, weight: .medium))
            .controlSize(.large)
    }

    /// Surfaces are Liquid Glass panes floating over the aurora.
    func card(radius: CGFloat = 20) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// `@State` is a macro in the macOS 27 SDK and the Command Line Tools ship no SwiftUI macro
/// plugin. The property wrapper still exists; reaching it through an alias bypasses the macro.
typealias ViewState = SwiftUI.State
