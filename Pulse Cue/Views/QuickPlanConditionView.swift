//
//  QuickPlanConditionView.swift
//  Pulse Cue
//
//  Quick Plan entry: pick today's conditions — one or more body parts, a
//  duration, and an intensity — then push into the shared
//  `GeneratedPlanPreviewView`. No new generator or store: the CTA builds a
//  `QuickPlanRequest` and the existing preview / RoutineFactory path takes
//  over. Multi-select body parts are kept in tap order so the generated
//  plan's round-robin coverage is predictable.
//

import SwiftUI

struct QuickPlanConditionView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let gym: Gym

    @State private var selectedParts: [BodyPart] = [.chest]
    @State private var duration: QuickPlanDuration = .standardPlus
    @State private var intensity: QuickPlanIntensity = .standard

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    private var request: QuickPlanRequest {
        QuickPlanRequest(bodyParts: selectedParts, duration: duration, intensity: intensity)
    }

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summaryCard
                    bodyPartCard
                    durationCard
                    intensityCard
                    if dynamicTypeSize.isAccessibilitySize {
                        ctaBar
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !dynamicTypeSize.isAccessibilitySize {
                ctaBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(PulseGlassPlate(level: .functional, cornerRadius: 20))
            }
        }
        .navigationTitle("今日のメニュー")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日の条件を選ぶ")
                .font(.title2.weight(.bold))
            Label(gym.name, systemImage: "building.2.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text("部位・時間・強度から、このジムで使えるマシンで今日のメニューを組み立てます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .pulseGlass(level: .hero, cornerRadius: AppTheme.heroRadius, padding: 20)
    }

    // MARK: - Body parts (multi-select)

    private var bodyPartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            PulseSectionHeader("鍛えたい部位（複数選択可）", icon: "target")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BodyPart.allCases) { part in
                    Button {
                        toggle(part)
                    } label: {
                        gridTile(for: part, isSelected: selectedParts.contains(part))
                    }
                    .buttonStyle(.plain)
                }
            }
            if selectedParts.isEmpty {
                Text("少なくとも1つの部位を選んでください。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .pulseGlass(level: .functional, padding: 18)
    }

    private func gridTile(for part: BodyPart, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: bodyPartIcon(part))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(AppTheme.accent))
                .frame(width: 30)
            Text(part.displayName)
                .font(.headline)
                .foregroundStyle(isSelected ? .white : .primary)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 56)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(AppTheme.accentFilled) : AnyShapeStyle(Color.secondary.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Duration

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseSectionHeader("時間", icon: "clock")
            Picker("時間", selection: $duration) {
                ForEach(QuickPlanDuration.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        .pulseGlass(level: .functional, padding: 18)
    }

    // MARK: - Intensity

    private var intensityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            PulseSectionHeader("強度", icon: "flame")
            Picker("強度", selection: $intensity) {
                ForEach(QuickPlanIntensity.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        .pulseGlass(level: .functional, padding: 18)
    }

    // MARK: - CTA

    private var ctaBar: some View {
        NavigationLink {
            GeneratedPlanPreviewView(gym: gym, request: request)
        } label: {
            Label("メニューを見る", systemImage: "sparkles")
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(PulsePrimaryButtonStyle(isEnabled: !selectedParts.isEmpty))
        .disabled(selectedParts.isEmpty)
    }

    // MARK: - Helpers

    /// Toggles a body part while preserving tap order for the round-robin
    /// generator.
    private func toggle(_ part: BodyPart) {
        if let index = selectedParts.firstIndex(of: part) {
            selectedParts.remove(at: index)
        } else {
            selectedParts.append(part)
        }
    }

    private func bodyPartIcon(_ part: BodyPart) -> String {
        switch part {
        case .chest: return "figure.strengthtraining.traditional"
        case .back: return "figure.walk"
        case .legs: return "figure.run"
        case .shoulders: return "figure.archery"
        case .arms: return "dumbbell.fill"
        case .core: return "figure.core.training"
        case .fullBody: return "figure.mixed.cardio"
        }
    }
}
