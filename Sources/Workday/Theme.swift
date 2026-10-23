import SwiftUI
import WorkdayCore

/// Visual tokens. Colours are chosen per colour scheme explicitly so they render identically in
/// live windows and in offscreen snapshots.
enum Theme {
    static let orange = Color(red: 1.0, green: 0.55, blue: 0.08)
    static let orangeDeep = Color(red: 0.93, green: 0.40, blue: 0.02)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.32)
    /// Text drawn on top of the liquid (high contrast against orange in both appearances).
    static let onLiquid = Color(red: 0.23, green: 0.09, blue: 0.0)

    static func windowBackground(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.105, green: 0.098, blue: 0.094) : Color(red: 0.965, green: 0.955, blue: 0.94)
    }

    static func panelBackground(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.15, green: 0.14, blue: 0.135) : Color.white
    }

    static func tileBase(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.17, green: 0.16, blue: 0.155) : Color.white
    }

    static func tileBorder(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }

    static func subtleFill(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    static func secondaryText(_ s: ColorScheme) -> Color {
        s == .dark ? Color.white.opacity(0.62) : Color.black.opacity(0.55)
    }

    static func liquidTop(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 1.0, green: 0.69, blue: 0.26) : Color(red: 1.0, green: 0.74, blue: 0.33)
    }

    static func liquidBottom(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.91, green: 0.37, blue: 0.02) : Color(red: 0.97, green: 0.45, blue: 0.05)
    }

    static let liquidBack = Color(red: 1.0, green: 0.62, blue: 0.18)
}

/// Compact pill button used across the popover and calendar (pure SwiftUI so it renders in snapshots).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, plain }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: kind == .primary ? .semibold : .medium))
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 8)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onLiquid
        case .destructive: return Color(red: 0.85, green: 0.2, blue: 0.15)
        case .secondary, .plain: return scheme == .dark ? .white.opacity(0.9) : .black.opacity(0.8)
        }
    }

    private func background(pressed: Bool) -> AnyShapeStyle {
        switch kind {
        case .primary:
            return AnyShapeStyle(LinearGradient(colors: [Theme.amber, Theme.orange], startPoint: .top, endPoint: .bottom)
                .opacity(pressed ? 0.85 : 1))
        case .secondary, .destructive:
            return AnyShapeStyle(Theme.subtleFill(scheme).opacity(pressed ? 2 : 1))
        case .plain:
            return AnyShapeStyle(Color.clear)
        }
    }

    private var border: Color {
        kind == .primary ? Theme.orangeDeep.opacity(0.5) : (kind == .plain ? .clear : Theme.tileBorder(scheme))
    }
}

/// Segmented control drawn in SwiftUI.
struct SegmentedSwitch<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == option.0 ? Theme.onLiquid : Theme.secondaryText(scheme))
                        .background {
                            if selection == option.0 {
                                Capsule().fill(LinearGradient(colors: [Theme.amber, Theme.orange], startPoint: .top, endPoint: .bottom))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.subtleFill(scheme), in: Capsule())
    }
}

/// Thin progress line used for goal progress.
struct ProgressLine: View {
    var progress: Double
    var height: CGFloat = 6
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtleFill(scheme))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.amber, Theme.orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, progress))))
                    .opacity(progress > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.4), value: progress)
    }
}

extension DateFormatter {
    static func make(_ template: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static func time(calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale.autoupdatingCurrent
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }
}
