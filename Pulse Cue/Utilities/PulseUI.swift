//
//  PulseUI.swift
//  Pulse Cue
//
//  Reusable "Apple Health Light" visual primitives built on `AppTheme`.
//  These give future UI PRs a shared, calmer tone — soft translucent cards,
//  subtle blue-gray borders, softer shadows, and a clear Primary / Secondary
//  / Tertiary action hierarchy — without redesigning any existing screen.
//
//  Layout-only. No model / persistence / networking dependencies. Applying
//  these primitives is opt-in: existing screens keep their current styling
//  until a future PR adopts them deliberately.
//

import SwiftUI

// MARK: - Atmosphere

/// A quiet, static field of light. It creates depth without a live blur or
/// continuous animation and deliberately leaves most of the canvas empty.
struct PulseAtmosphericBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var focused = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let darkField = focused || colorScheme == .dark
            ZStack {
                LinearGradient(
                    colors: darkField
                        ? [AppTheme.deepSpace, Color(red: 0.01, green: 0.08, blue: 0.17), AppTheme.deepSpace]
                        : [Color.white, AppTheme.atmosphericBase, Color.white],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Ellipse()
                    .fill((darkField ? AppTheme.deepGlass : AppTheme.iceLight).opacity(darkField ? 0.72 : 0.46))
                    .frame(width: size.width * 0.92, height: size.height * 0.34)
                    .blur(radius: darkField ? 54 : 42)
                    .position(x: size.width * 0.82, y: size.height * 0.18)

                Capsule()
                    .fill((darkField ? AppTheme.edgeBlue : Color.white).opacity(darkField ? 0.22 : 0.84))
                    .frame(width: size.width * 0.84, height: 86)
                    .rotationEffect(.degrees(-18))
                    .blur(radius: 18)
                    .position(x: size.width * 0.24, y: size.height * 0.40)

                Ellipse()
                    .fill(AppTheme.reflectedBlue.opacity(darkField ? 0.34 : 0.18))
                    .frame(width: size.width * 0.76, height: size.height * 0.28)
                    .blur(radius: darkField ? 62 : 54)
                    .position(x: size.width * 0.12, y: size.height * 0.72)

                Capsule()
                    .fill(AppTheme.iceLight.opacity(darkField ? 0.14 : 0.34))
                    .frame(width: size.width * 0.62, height: 44)
                    .rotationEffect(.degrees(24))
                    .blur(radius: 12)
                    .position(x: size.width * 0.82, y: size.height * 0.60)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Card

/// A soft, translucent white card with a subtle blue-gray border and a gentle
/// shadow. The Apple Health Light counterpart to the heavier frosted
/// `myGymCard`.
struct PulseCard<Content: View>: View {
    var padding: CGFloat = AppTheme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .pulseCard(padding: padding)
    }
}

extension View {
    /// Wraps the view in the standard Pulse card surface.
    func pulseCard(padding: CGFloat = AppTheme.Spacing.l) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [AppTheme.glassEdge, AppTheme.separator.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: AppTheme.deepGlass.opacity(0.10), radius: 18, x: 0, y: 10)
    }

    /// Applies the airy app background, ignoring safe areas.
    func pulseScreenBackground() -> some View {
        background(PulseAtmosphericBackground())
    }
}

// MARK: - Art-directed Glass

enum PulseGlassLevel {
    case subtle
    case functional
    case hero

    var material: Material {
        switch self {
        case .subtle: return .ultraThinMaterial
        case .functional: return .thinMaterial
        case .hero: return .regularMaterial
        }
    }

    var tintOpacity: Double {
        switch self {
        case .subtle: return 0.06
        case .functional: return 0.11
        case .hero: return 0.16
        }
    }

    var edgeWidth: CGFloat {
        switch self {
        case .subtle: return 0.6
        case .functional: return 0.9
        case .hero: return 1.2
        }
    }
}

/// Physical-looking glass plate with one consistent light direction:
/// cool white from the upper-left and a cyan reflection at lower-right.
struct PulseGlassPlate: View {
    @Environment(\.colorScheme) private var colorScheme

    let level: PulseGlassLevel
    var focused = false
    var cornerRadius: CGFloat = AppTheme.glassRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let darkPlate = focused || colorScheme == .dark

        shape
            .fill(level.material)
            .overlay {
                shape.fill(
                    darkPlate
                        ? AppTheme.deepGlass.opacity(level.tintOpacity + 0.08)
                        : Color.white.opacity(level.tintOpacity)
                )
            }
            .overlay {
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(darkPlate ? 0.20 : 0.52), location: 0),
                            .init(color: Color.white.opacity(0.04), location: 0.32),
                            .init(color: Color.clear, location: 0.58),
                            .init(color: AppTheme.iceLight.opacity(darkPlate ? 0.12 : 0.18), location: 1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.clear, Color.white.opacity(darkPlate ? 0.54 : 0.92), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: level == .hero ? 1.5 : 1)
                .padding(.horizontal, cornerRadius)
                .padding(.top, 1)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(darkPlate ? 0.72 : 0.98),
                            AppTheme.iceLight.opacity(darkPlate ? 0.42 : 0.66),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: level.edgeWidth
                )
            }
            .shadow(
                color: darkPlate
                    ? AppTheme.deepGlass.opacity(level == .hero ? 0.54 : 0.34)
                    : AppTheme.reflectedBlue.opacity(level == .hero ? 0.22 : 0.12),
                radius: level == .hero ? 28 : 16,
                x: 0,
                y: level == .hero ? 18 : 10
            )
    }
}

extension View {
    func pulseGlass(
        level: PulseGlassLevel = .functional,
        focused: Bool = false,
        cornerRadius: CGFloat = AppTheme.glassRadius,
        padding: CGFloat = AppTheme.Spacing.l
    ) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background {
                PulseGlassPlate(level: level, focused: focused, cornerRadius: cornerRadius)
            }
    }
}

// MARK: - Section header

/// A quiet section header: optional accent icon + bold title. Mirrors the
/// existing `sectionHeader` helpers but with the restrained accent.
struct PulseSectionHeader: View {
    let title: String
    var icon: String?

    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.s) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
            }
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Button styles (Primary / Secondary / Tertiary hierarchy)

/// Primary CTA — solid restrained-blue fill. One per context.
struct PulsePrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        PulseButtonBody(variant: .primary, manualEnabled: isEnabled, configuration: configuration)
    }
}

/// Secondary CTA — tinted accent fill with a hairline border. Supports a
/// primary without competing with it.
struct PulseSecondaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        PulseButtonBody(variant: .secondary, manualEnabled: isEnabled, configuration: configuration)
    }
}

/// Tertiary / quiet action — text-only accent, no fill. For low-emphasis
/// actions (e.g. "後で", inline links).
struct PulseTertiaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        PulseButtonBody(variant: .tertiary, manualEnabled: isEnabled, configuration: configuration)
    }
}

/// Shared label body for the Pulse button styles. A `ButtonStyle`'s
/// `makeBody` cannot read `@Environment`, so the rendered visuals live in
/// this `View` where `@Environment(\.isEnabled)` is available. The disabled
/// appearance therefore follows SwiftUI's `.disabled(...)` as well as the
/// style's manual `isEnabled` flag.
struct PulseButtonBody: View {
    enum Variant { case primary, secondary, tertiary }

    @Environment(\.isEnabled) private var environmentIsEnabled

    let variant: Variant
    let manualEnabled: Bool
    let configuration: ButtonStyle.Configuration

    /// The visual enabled state: enabled only when both the manual flag and
    /// the `.disabled(...)` environment are enabled.
    static func isEffectivelyEnabled(manual: Bool, environment: Bool) -> Bool {
        manual && environment
    }

    private var effectiveEnabled: Bool {
        Self.isEffectivelyEnabled(manual: manualEnabled, environment: environmentIsEnabled)
    }

    var body: some View {
        switch variant {
        case .primary: primary
        case .secondary: secondary
        case .tertiary: tertiary
        }
    }

    private var primary: some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .fill(effectiveEnabled ? AnyShapeStyle(AppTheme.accentFilled) : AnyShapeStyle(Color.gray.opacity(0.35)))
                    .shadow(color: effectiveEnabled ? AppTheme.accent.opacity(0.22) : .clear,
                            radius: 8, x: 0, y: 4)
            )
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }

    private var secondary: some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(effectiveEnabled ? AppTheme.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.Spacing.m)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .fill(AppTheme.accentSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                    .strokeBorder(AppTheme.accent.opacity(effectiveEnabled ? 0.30 : 0.12), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }

    private var tertiary: some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(effectiveEnabled ? AppTheme.accent : Color.secondary)
            .padding(.vertical, AppTheme.Spacing.s)
            .padding(.horizontal, AppTheme.Spacing.s)
            .opacity(configuration.isPressed ? 0.55 : 1.0)
    }
}

// MARK: - Status badge

/// A small, capsule status badge with a calm tint. Useful for "保存済み",
/// "DEBUG", warnings, etc.
struct PulseStatusBadge: View {
    enum Kind {
        case info
        case success
        case warning

        var tint: Color {
            switch self {
            case .info: return AppTheme.info
            case .success: return AppTheme.success
            case .warning: return AppTheme.warning
            }
        }

        var systemImage: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            }
        }
    }

    let kind: Kind
    let text: String

    init(_ text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: kind.systemImage)
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, AppTheme.Spacing.s)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(Capsule().fill(kind.tint.opacity(0.15)))
        .foregroundStyle(kind.tint)
    }
}

// MARK: - Preview (minimal example usage)

#if DEBUG
#Preview("Pulse UI foundation") {
    ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
            PulseSectionHeader("Apple Health Light", icon: "heart.text.square")

            PulseCard {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                    HStack {
                        Text("今日のプラン")
                            .font(.headline)
                        Spacer()
                        PulseStatusBadge("保存済み", kind: .success)
                    }
                    Text("落ち着いた、読みやすいトーン。カードは柔らかく、影は控えめ。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.textSecondary)

                    Button("プランを保存") {}
                        .buttonStyle(PulsePrimaryButtonStyle())
                    Button("内容を編集") {}
                        .buttonStyle(PulseSecondaryButtonStyle())
                    Button("後で") {}
                        .buttonStyle(PulseTertiaryButtonStyle())
                }
            }

            PulseCard {
                HStack(spacing: AppTheme.Spacing.s) {
                    PulseStatusBadge("情報", kind: .info)
                    PulseStatusBadge("注意", kind: .warning)
                }
            }
        }
        .padding(AppTheme.Spacing.l)
    }
    .pulseScreenBackground()
}
#endif
