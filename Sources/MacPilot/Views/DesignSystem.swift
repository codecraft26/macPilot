import AppKit
import SwiftUI

/// Spacing, radii, colors and reusable pieces so every screen looks like one app.
enum DS {
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let tile: CGFloat = 7
    }

    /// Brand colors taken from the app icon (indigo → violet).
    static let indigo = Color(red: 0.33, green: 0.36, blue: 0.98)
    static let violet = Color(red: 0.60, green: 0.30, blue: 0.95)
    static let accent = Color(red: 0.42, green: 0.36, blue: 0.97)
    static let brandGradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Semantic surfaces that adapt to light and dark mode.
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let inset = Color(nsColor: .textBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    static let subtleFill = Color.primary.opacity(0.05)
}

extension AppSection {
    /// Icon tile color in the sidebar and headers (System Settings style).
    var tint: Color {
        switch self {
        case .dashboard: return DS.indigo
        case .assistant: return DS.violet
        case .voice: return .pink
        case .calendar: return .red
        case .notes: return .orange
        case .tasks: return .blue
        case .clipboard: return .teal
        case .developer: return .gray
        case .automations: return .green
        case .settings: return Color(nsColor: .systemGray)
        }
    }

    var group: String {
        switch self {
        case .dashboard, .assistant, .voice, .calendar: return "Workspace"
        case .notes, .tasks, .clipboard: return "Organize"
        case .developer, .automations: return "Build"
        case .settings: return ""
        }
    }
}

/// A white SF Symbol on a colored rounded square.
struct IconTile: View {
    let systemImage: String
    var color: Color = DS.accent
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = DS.Space.m

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).fill(DS.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous).strokeBorder(DS.hairline))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

extension View {
    func card(padding: CGFloat = DS.Space.m) -> some View { modifier(CardModifier(padding: padding)) }

    /// Rounded inset well for editors and code.
    func insetWell(radius: CGFloat = DS.Radius.medium) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(DS.inset))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.hairline))
    }
}

/// Title row used at the top of cards and sections.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var systemImage: String?
    var color: Color = DS.accent
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            if let systemImage { IconTile(systemImage: systemImage, color: color, size: 20) }
            Text(title).font(.headline)
            Spacer(minLength: DS.Space.xs)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, systemImage: String? = nil, color: Color = DS.accent) {
        self.init(title: title, systemImage: systemImage, color: color) { EmptyView() }
    }
}

/// Icon, one-line explanation and an optional primary action.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var compact = false

    var body: some View {
        VStack(spacing: compact ? DS.Space.xs : DS.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: compact ? 22 : 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(compact ? .callout.weight(.medium) : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .small : .regular)
                    .padding(.top, DS.Space.xxs)
            }
        }
        .padding(compact ? DS.Space.s : DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity)
    }
}

/// Small rounded label, e.g. a keyboard shortcut or count.
struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

/// Row background that highlights on hover, for clickable rows.
struct HoverHighlight: ViewModifier {
    var isSelected = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(isSelected ? DS.accent.opacity(0.18) : (hovering ? DS.subtleFill : .clear))
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight(selected: Bool = false) -> some View { modifier(HoverHighlight(isSelected: selected)) }
}

/// Behind-window blur for the floating panels (Raycast/Spotlight look).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Three dots that pulse while a reply streams in.
struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(index == phase ? 1 : 0.35)
                }
            }
        }
        .accessibilityLabel("Writing a reply")
    }
}

/// Marks events that come from Google Calendar.
struct GoogleBadge: View {
    var body: some View {
        Text("G")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Color.blue))
            .help("Google Calendar")
            .accessibilityLabel("Google Calendar")
    }
}
