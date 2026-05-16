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
    let gym: Gym
    @State private var selection: BodyPart = .chest

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            MyGymStyle.backgroundLayer(for: colorScheme)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard
                    gridCard
                    Color.clear.frame(height: 88)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            ctaBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .navigationTitle("部位を選択")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            MyGymStyle.sectionHeader(icon: "building.2.fill", title: gym.name)
            Text("選んだ部位に合わせて、このジムにあるマシンからメニューを自動で組み立てます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .myGymCard()
    }

    private var gridCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            MyGymStyle.sectionHeader(icon: "target", title: "鍛えたい部位")
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
        .myGymCard()
    }

    private func gridTile(for part: BodyPart, isSelected: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: bodyPartIcon(part))
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(MyGymStyle.accentGradient))
                .frame(height: 30)
            Text(part.displayName)
                .font(.headline)
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(MyGymStyle.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.08)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.clear : Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var ctaBar: some View {
        NavigationLink {
            GeneratedPlanPreviewView(gym: gym, bodyPart: selection)
        } label: {
            Label("\(selection.displayName)のメニューを生成", systemImage: "sparkles")
        }
        .buttonStyle(MyGymPrimaryButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
                .padding(-6)
        )
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
