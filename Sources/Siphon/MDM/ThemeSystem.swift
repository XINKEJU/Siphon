import SwiftUI
import AppKit

/// MDM separates *roles* from colours: drawing code asks for
/// `list.row.hot` or `meter.fill`, never for a literal colour. Themes then
/// supply role values. Siphon's views adopt the same contract so a theme can
/// be swapped without touching layout code.
public enum MDMRole: String, CaseIterable, Sendable {
    case listBackground, listRow, listRowAlternate, listRowHot
    case selection, selectionFocus
    case caption, text, secondaryText
    case buttonHot, buttonPressed, defaultButtonBorder
    case meterFill, progressBar
    case error, warning, success
    case tabPage, groupLine, fieldBorder
    case surface, surfaceRaised
}

public enum MDMTheme: String, CaseIterable, Sendable, Identifiable {
    case classic, native, highContrast, metro, adwaita, breeze
    case luna, aero, aqua, emerald

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .native: return "Native"
        case .highContrast: return MDMI18n.t("theme.highContrast")
        case .metro: return "Metro"
        case .adwaita: return "Adwaita"
        case .breeze: return "Breeze"
        case .luna: return "Luna"
        case .aero: return "Aero"
        case .aqua: return "Aqua"
        case .emerald: return "Emerald"
        }
    }
}

public enum MDMAppearance: String, CaseIterable, Sendable {
    case system, light, dark
}

/// Observable theme state, persisted with the same `Siphon.*` key convention
/// as the rest of the app. Interface size follows MDM's 100–200% range.
@MainActor
public final class MDMThemeStore: ObservableObject {
    public static let shared = MDMThemeStore()

    @Published public var theme: MDMTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "Siphon.mdm.theme") }
    }
    @Published public var appearance: MDMAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "Siphon.mdm.appearance")
            applyAppearance()
        }
    }
    @Published public var scale: Double {
        didSet { UserDefaults.standard.set(scale, forKey: "Siphon.mdm.interfaceScale") }
    }

    private init() {
        let d = UserDefaults.standard
        theme = MDMTheme(rawValue: d.string(forKey: "Siphon.mdm.theme") ?? "") ?? .classic
        appearance = MDMAppearance(rawValue: d.string(forKey: "Siphon.mdm.appearance") ?? "") ?? .system
        scale = min(2.0, max(1.0, d.double(forKey: "Siphon.mdm.interfaceScale") == 0
                             ? 1.0 : d.double(forKey: "Siphon.mdm.interfaceScale")))
        // A theme's light/dark choice must reach every window (dialogs, popup,
        // settings), not just the main view. Setting the application appearance
        // makes AppKit controls and system semantic colours follow as well.
        applyAppearance()
    }

    private func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    public var isDark: Bool {
        switch appearance {
        case .light: return false
        case .dark: return true
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// Role lookup. Every value is explicit: SwiftUI has no fallback colour
    /// here, and an accidental `.clear` would make the list unreadable.
    public func color(_ role: MDMRole) -> Color {
        let dark = isDark
        switch theme {
        case .classic: return classic(role, dark: dark)
        case .highContrast: return highContrast(role, dark: dark)
        case .native: return native(role, dark: dark)
        case .metro: return tinted(role, dark: dark, hue: 0.58, sat: 0.62)
        case .adwaita: return tinted(role, dark: dark, hue: 0.60, sat: 0.48)
        case .breeze: return tinted(role, dark: dark, hue: 0.56, sat: 0.55)
        case .luna: return tinted(role, dark: dark, hue: 0.57, sat: 0.70)
        case .aero: return tinted(role, dark: dark, hue: 0.55, sat: 0.58)
        case .aqua: return tinted(role, dark: dark, hue: 0.52, sat: 0.66)
        case .emerald: return tinted(role, dark: dark, hue: 0.38, sat: 0.55)
        }
    }

    public func scaled(_ points: CGFloat) -> CGFloat { points * CGFloat(scale) }

    /// Font that actually grows with the interface scale, instead of a bitmap
    /// `scaleEffect` that only stretches pixels.
    public func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * CGFloat(scale), weight: weight)
    }

    /// Monospaced variant for paths, sizes and hashes.
    public func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * CGFloat(scale), weight: weight, design: .monospaced)
    }

    /// Text styles (`.caption`, `.body`, …) follow the same interface scale, so
    /// panes that rely on system styles grow with the list and dialogs.
    public var dynamicTypeSize: DynamicTypeSize {
        switch scale {
        case ..<1.10: return .large
        case ..<1.20: return .xLarge
        case ..<1.35: return .xxLarge
        case ..<1.60: return .xxxLarge
        case ..<1.80: return .accessibility1
        default: return .accessibility2
        }
    }

    /// Scaled metrics for controls, rows and spacing.
    public var metrics: MDMMetrics { MDMMetrics(scale: CGFloat(scale)) }

    // MARK: - Palettes

    private func classic(_ role: MDMRole, dark: Bool) -> Color {
        switch role {
        case .listBackground: return dark ? Color(0.11, 0.12, 0.14) : Color(1, 1, 1)
        case .listRow: return dark ? Color(0.13, 0.14, 0.17) : Color(1, 1, 1)
        case .listRowAlternate: return dark ? Color(0.15, 0.16, 0.19) : Color(0.96, 0.97, 0.99)
        case .listRowHot: return dark ? Color(0.20, 0.24, 0.30) : Color(0.88, 0.94, 1.0)
        case .selection: return dark ? Color(0.20, 0.36, 0.58) : Color(0.82, 0.90, 1.0)
        case .selectionFocus: return Color(0.95, 0.55, 0.20)
        case .caption: return dark ? Color(0.72, 0.75, 0.80) : Color(0.40, 0.43, 0.48)
        case .text: return dark ? Color(0.94, 0.95, 0.97) : Color(0.11, 0.12, 0.15)
        case .secondaryText: return dark ? Color(0.68, 0.71, 0.76) : Color(0.40, 0.42, 0.47)
        case .buttonHot: return dark ? Color(0.22, 0.26, 0.32) : Color(0.94, 0.95, 0.97)
        case .buttonPressed: return dark ? Color(0.30, 0.35, 0.42) : Color(0.84, 0.87, 0.92)
        case .defaultButtonBorder: return Color(0.20, 0.42, 0.78)
        case .meterFill: return Color(0.22, 0.66, 0.32)
        case .progressBar: return Color(0.20, 0.44, 0.82)
        case .error: return Color(0.82, 0.24, 0.24)
        case .warning: return Color(0.86, 0.55, 0.12)
        case .success: return Color(0.20, 0.62, 0.30)
        case .tabPage: return dark ? Color(0.17, 0.19, 0.23) : Color(0.97, 0.97, 0.98)
        case .groupLine: return dark ? Color(0.30, 0.32, 0.36) : Color(0.78, 0.79, 0.82)
        case .fieldBorder: return dark ? Color(0.38, 0.40, 0.44) : Color(0.66, 0.68, 0.72)
        case .surface: return dark ? Color(0.14, 0.15, 0.18) : Color(0.99, 0.99, 1.0)
        case .surfaceRaised: return dark ? Color(0.18, 0.20, 0.24) : Color(0.95, 0.96, 0.98)
        }
    }

    private func highContrast(_ role: MDMRole, dark: Bool) -> Color {
        switch role {
        case .listBackground, .surface: return dark ? .black : .white
        case .listRow, .tabPage: return dark ? .black : .white
        case .listRowAlternate: return dark ? Color(0.08, 0.08, 0.08) : Color(0.92, 0.92, 0.92)
        case .listRowHot, .buttonHot: return dark ? Color(0.25, 0.25, 0.25) : Color(0.80, 0.80, 0.80)
        case .selection: return dark ? Color(0.00, 0.55, 1.0) : Color(0.70, 0.85, 1.0)
        case .selectionFocus: return dark ? Color.yellow : Color(0.70, 0.30, 0)
        case .caption, .text, .secondaryText: return dark ? .white : .black
        case .buttonPressed: return dark ? Color(0.40, 0.40, 0.40) : Color(0.65, 0.65, 0.65)
        case .defaultButtonBorder: return dark ? .white : .black
        case .meterFill: return dark ? Color(0.20, 1.0, 0.30) : Color(0, 0.55, 0)
        case .progressBar: return dark ? Color(0.20, 0.70, 1.0) : Color(0, 0.25, 0.75)
        case .error: return dark ? Color(1.0, 0.35, 0.35) : Color(0.65, 0, 0)
        case .warning: return dark ? Color(1.0, 0.75, 0.10) : Color(0.60, 0.35, 0)
        case .success: return dark ? Color(0.30, 1.0, 0.40) : Color(0, 0.50, 0)
        case .groupLine, .fieldBorder, .surfaceRaised: return dark ? .white : .black
        }
    }

    private func native(_ role: MDMRole, dark: Bool) -> Color {
        switch role {
        case .meterFill: return Color(nsColor: .systemGreen)
        case .progressBar, .selection, .defaultButtonBorder: return Color.accentColor
        case .error: return Color(nsColor: .systemRed)
        case .warning: return Color(nsColor: .systemOrange)
        case .success: return Color(nsColor: .systemGreen)
        case .caption, .secondaryText: return Color(nsColor: .secondaryLabelColor)
        case .text: return Color(nsColor: .labelColor)
        case .groupLine, .fieldBorder: return Color(nsColor: .separatorColor)
        case .surface, .surfaceRaised: return Color(nsColor: .controlBackgroundColor)
        case .selectionFocus: return Color(nsColor: .systemOrange)
        default: return classic(role, dark: dark)
        }
    }

    /// The remaining built-in themes share geometry with Classic and shift
    /// only the accent channel — MDM does the same: themes change colour
    /// roles, never the IDM pixel layout.
    private func tinted(_ role: MDMRole, dark: Bool, hue: Double, sat: Double) -> Color {
        let accent = Color(hue: hue, saturation: sat, brightness: dark ? 0.95 : 0.78)
        switch role {
        case .progressBar, .selection, .defaultButtonBorder, .buttonHot:
            return accent
        case .selectionFocus: return Color(hue: hue, saturation: sat, brightness: dark ? 0.70 : 0.55)
        case .meterFill, .success: return Color(hue: 0.34, saturation: 0.62, brightness: dark ? 0.80 : 0.62)
        default: return classic(role, dark: dark)
        }
    }
}

private extension Color {
    init(_ r: Double, _ g: Double, _ b: Double) {
        self.init(red: r, green: g, blue: b)
    }
}

/// Scaled layout metrics consumed by SwiftUI and AppKit table cells.
public struct MDMMetrics: Sendable {
    public let scale: CGFloat

    public init(scale: CGFloat = 1.0) { self.scale = scale }

    public var rowHeight: CGFloat { 22 * scale }
    public var headerHeight: CGFloat { 24 * scale }
    public var cellPadding: CGFloat { 4 * scale }
    public var controlMinHeight: CGFloat { 20 * scale }
    public var buttonPadding: CGFloat { 6 * scale }
    public var sectionSpacing: CGFloat { 14 * scale }
    public var captionSize: CGFloat { 11 * scale }
    public var bodySize: CGFloat { 13 * scale }
    public var titleSize: CGFloat { 15 * scale }

    public func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }
}
