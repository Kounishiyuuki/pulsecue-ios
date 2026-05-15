//
//  GymCandidateRow.swift
//  Pulse Cue
//
//  One result in the gym candidate search list. Name + address are
//  primary; the optional website hostname and source label form a
//  secondary metadata line; the「選択」button on the trailing edge
//  commits the candidate as the registration prefill.
//

import SwiftUI

struct GymCandidateRow: View {
    let candidate: GymCandidate
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                if !candidate.address.isEmpty {
                    Text(candidate.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                metadataLine
            }
            Spacer(minLength: 8)
            Button(action: onSelect) {
                Text("選択")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var metadataLine: some View {
        HStack(spacing: 6) {
            if let host = candidate.hostnameForDisplay {
                Label(host, systemImage: "globe")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(candidate.sourceLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
