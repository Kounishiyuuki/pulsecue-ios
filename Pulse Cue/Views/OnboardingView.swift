import SwiftUI

/// Calm first entry: understand local-first use, then start as a guest.
struct OnboardingView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var primaryTitle: String = "ゲストで始める"
    var onPrimary: () -> Void

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    hero
                    localFirstMessage
                    if dynamicTypeSize.isAccessibilitySize {
                        primaryAction
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 54)
                .padding(.bottom, 32)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                primaryAction
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Circle().fill(AppTheme.accentFilled))
                .accessibilityHidden(true)

            Text("今日の自分に、\nちょうどいい一歩を。")
                .font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text("PulseCueは、トレーニングと日々の記録を静かに続けるためのアプリです。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localFirstMessage: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "iphone")
                .font(.headline)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("ログインなしで始められます")
                    .font(.headline)
                Text("現在のデータはこの端末内に保存されます。アカウント連携と同期は今後対応予定です。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pulseGlass(level: .subtle, padding: 18)
        .accessibilityElement(children: .combine)
    }

    private var primaryAction: some View {
        VStack(spacing: 8) {
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(PulsePrimaryButtonStyle())
            Text("あとから設定を変更できます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if DEBUG
#Preview {
    OnboardingView {}
}
#endif
