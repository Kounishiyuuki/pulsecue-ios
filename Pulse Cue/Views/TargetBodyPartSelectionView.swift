//
//  TargetBodyPartSelectionView.swift
//  Pulse Cue
//
//  Body part picker. Selecting a part pushes into the generated plan
//  preview. Stateless beyond the selection — no VM needed.
//

import SwiftUI

struct TargetBodyPartSelectionView: View {
    let gym: Gym
    @State private var selection: BodyPart = .chest

    var body: some View {
        List {
            Section {
                Text("「\(gym.name)」のマシンから、選んだ部位向けのワークアウトを自動で組み立てます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("部位") {
                ForEach(BodyPart.allCases) { part in
                    Button {
                        selection = part
                    } label: {
                        HStack {
                            Image(systemName: selection == part ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == part ? Color.accentColor : Color.secondary)
                                .imageScale(.large)
                            Text(part.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                NavigationLink {
                    GeneratedPlanPreviewView(gym: gym, bodyPart: selection)
                } label: {
                    Label("\(selection.displayName)のワークアウトを生成", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle("部位を選択")
        .navigationBarTitleDisplayMode(.inline)
    }
}
