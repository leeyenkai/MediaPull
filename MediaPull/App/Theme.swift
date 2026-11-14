import AppKit
import SwiftUI

/// Colour themes (SPEC R-2010): an accent for controls and selection, and a soft gradient for
/// pane title bars. "System" follows the accent colour chosen in System Settings.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, ocean, sunset, forest, lavender, graphite, roseGold, aurora, spectrum

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "System"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        case .forest: "Forest"
        case .lavender: "Lavender"
        case .graphite: "Graphite"
        case .roseGold: "Rose Gold"
        case .aurora: "Aurora"
        case .spectrum: "Spectrum"
        }
    }

    /// Gradient stops in sRGB, from the leading edge.
    private var stops: [(Double, Double, Double)] {
        switch self {
        case .system: []
        case .ocean: [(0.04, 0.42, 0.86), (0.10, 0.68, 0.86), (0.36, 0.85, 0.80)]
        case .sunset: [(0.96, 0.36, 0.30), (0.98, 0.56, 0.26), (0.99, 0.78, 0.36)]
        case .forest: [(0.10, 0.48, 0.32), (0.30, 0.64, 0.36), (0.62, 0.76, 0.38)]
        case .lavender: [(0.46, 0.38, 0.88), (0.66, 0.50, 0.92), (0.86, 0.64, 0.94)]
        case .graphite: [(0.30, 0.33, 0.38), (0.48, 0.51, 0.56), (0.66, 0.68, 0.72)]
        case .roseGold: [(0.78, 0.45, 0.48), (0.89, 0.62, 0.58), (0.95, 0.78, 0.66)]
        case .aurora: [(0.18, 0.80, 0.62), (0.22, 0.56, 0.90), (0.62, 0.36, 0.92)]
        case .spectrum: [(0.95, 0.27, 0.36), (0.98, 0.62, 0.20), (0.96, 0.86, 0.26), (0.30, 0.80, 0.42),
                         (0.18, 0.62, 0.95), (0.52, 0.38, 0.95), (0.86, 0.32, 0.80)]
        }
    }

    var colors: [Color] {
        stops.map { Color(.sRGB, red: $0.0, green: $0.1, blue: $0.2) }
    }

    /// The control and selection colour: the middle stop, or the system accent.
    var accent: Color {
        guard !stops.isEmpty else { return .accentColor }
        let middle = stops[self == .spectrum ? 4 : stops.count / 2]
        return Color(.sRGB, red: middle.0, green: middle.1, blue: middle.2)
    }

    var nsAccent: NSColor {
        guard !stops.isEmpty else { return .controlAccentColor }
        let middle = stops[self == .spectrum ? 4 : stops.count / 2]
        return NSColor(srgbRed: middle.0, green: middle.1, blue: middle.2, alpha: 1)
    }

    /// The full-strength gradient, for swatches and accents.
    var gradient: LinearGradient {
        LinearGradient(colors: colors.isEmpty ? [.accentColor, .accentColor.opacity(0.7)] : colors, startPoint: .leading, endPoint: .trailing)
    }

    /// A quiet wash behind pane titles that keeps text legible in light and dark appearances.
    var headerBackground: AnyShapeStyle {
        guard !stops.isEmpty else { return AnyShapeStyle(.clear) }
        return AnyShapeStyle(LinearGradient(colors: colors.map { $0.opacity(0.16) }, startPoint: .leading, endPoint: .trailing))
    }

    /// Read by AppKit views (the media grids), which cannot observe SwiftUI state.
    nonisolated(unsafe) static var currentAccent: NSColor = .controlAccentColor
}

/// A swatch for the theme picker.
struct ThemeSwatch: View {
    var theme: AppTheme
    var selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme == .system ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(theme.gradient))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? theme.accent : .clear, lineWidth: 2.5)
                        .padding(-4)
                }
                .frame(width: 64, height: 40)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            Text(theme.name).font(.caption).foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(4)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityLabel("\(theme.name) theme")
    }
}
