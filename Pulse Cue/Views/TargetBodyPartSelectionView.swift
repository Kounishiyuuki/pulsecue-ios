//
//  TargetBodyPartSelectionView.swift
//  Pulse Cue
//
//  Body part picker. Renders the seven `BodyPart` cases as large
//  tappable cards in a two-column grid; the selected card lights up
//  with the accent gradient. The primary CTA at the bottom pushes
//  into `GeneratedPlanPreviewView` with the chosen part.
//

import SwiftUI

struct TargetBodyPartSelectionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let gym: Gym
    @State private var selection: BodyPart = .chest

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 12)]

    var body: some View {
        ZStack {
            PulseAtmosphericBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summaryCard
                    gridCard
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
        .navigationTitle("部位を選択")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日はどこを鍛えますか？")
                .font(.title2.weight(.bold))
            Label(gym.name, systemImage: "building.2.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            Text("選んだ部位と、このジムで使えるマシンから今日のメニューを組み立てます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .pulseGlass(level: .hero, cornerRadius: AppTheme.heroRadius, padding: 20)
    }

    private var gridCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            PulseSectionHeader("鍛えたい部位", icon: "target")
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BodyPart.allCases) { part in
                    Button {
                        selection = part
                    } label: {
                        gridTile(for: part, isSelected: selection == part)
                    }
                    .buttonStyle(.plain)
                }
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

    private var ctaBar: some View {
        NavigationLink {
            GeneratedPlanPreviewView(gym: gym, bodyPart: selection)
        } label: {
            Label("\(selection.displayName)のメニューを生成", systemImage: "sparkles")
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(PulsePrimaryButtonStyle())
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
