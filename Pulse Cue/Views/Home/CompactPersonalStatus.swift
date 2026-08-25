//
//  CompactPersonalStatus.swift
//  Pulse Cue
//
//  Where the user stands, in one line.
//
//  This replaces a hero block that took most of the first viewport: a large
//  headline, a subhead, a 0/4 count and a stack of decorative plates. It was
//  the biggest thing on Home and it answered the smallest question.
//
//  The wording changed too, and that part is not cosmetic. It said
//  「今日の状態」 above a number that counts *how many fields you have filled
//  in* — nothing to do with how you are. A user reading "状態 0/4" reasonably
//  concludes the app has an opinion about their body. It does not, so it now
//  says 今日の記録.
//
//  Weight sits here rather than in a metrics grid because it is personal
//  status rather than a decision for today: useful to see, not something you
//  act on before training or eating.
//

import SwiftUI

struct CompactPersonalStatus: View {
    /// Recorded fields today, out of four. Purely a count of what has been
    /// entered — never a health assessment.
    let recordedCount: Int
    let totalCount: Int
    /// Latest logged weight, when there is one.
    let weightText: String?
    /// Distance to the goal weight, already formatted. Optional because a
    /// goal is optional.
    let goalDifferenceText: String?
    /// Opens the weight quick input.
    ///
    /// Only the weight portion is the button. The row used to be one large
    /// tap target labelled 今日の記録 that opened weight entry — a promise the
    /// label did not make, and one a VoiceOver user had no way to predict.
    let onTapWeight: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("今日の記録")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(recordedCount) / \(totalCount) 入力済み")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(recordAccessibilityLabel)

            Spacer(minLength: 0)

            if let weightText {
                Divider().frame(height: 26)

                Button(action: onTapWeight) {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("体重")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(weightText)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let goalDifferenceText {
                                    Text(goalDifferenceText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(weightAccessibilityLabel)
                .accessibilityHint("体重を入力")
                .accessibilityAddTraits(.isButton)
            } else {
                Button(action: onTapWeight) {
                    Text("体重を記録")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("体重を入力")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        // Deliberately lighter than the Training and Nutrition cards: it is
        // context, and context should not look like a decision.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardBackground.opacity(0.5))
        )
        // Wraps rather than shrinks at accessibility sizes.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recordAccessibilityLabel: String {
        "今日の記録 \(totalCount) 項目中 \(recordedCount) 項目入力済み"
    }

    private var weightAccessibilityLabel: String {
        var parts = ["体重"]
        if let weightText { parts.append(weightText) }
        if let goalDifferenceText { parts.append(goalDifferenceText) }
        return parts.joined(separator: " ")
    }

}
