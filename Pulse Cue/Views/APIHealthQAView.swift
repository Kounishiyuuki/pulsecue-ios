//
//  APIHealthQAView.swift
//  Pulse Cue
//
//  DEBUG-only manual QA tool to check a custom API health endpoint using the
//  existing API foundation (PR #122/#123). The ENTIRE file is compiled out of
//  Release (`#if DEBUG`), so no UI or strings here can reach a shipping build.
//
//  Boundaries:
//    - **Manual only.** A check runs ONLY when the user taps the button; there
//      is no automatic / on-appear networking.
//    - **In-memory base URL only.** The field has no default and is never
//      persisted (no UserDefaults / Keychain). There is no production /
//      Worker URL default.
//    - **No token field.** This QA does not send any Authorization header.
//    - **Read-only probe.** The check is a body-less GET; no user data is sent.
//    - This is development QA only — NOT a user-facing feature, and it does
//      not imply that API sync / account backup is active.
//

#if DEBUG
import SwiftUI

struct APIHealthQAView: View {
    /// In-memory only. No default, never persisted.
    @State private var baseURLString: String = ""
    @State private var isChecking = false
    @State private var result: APIHealthQAResult?

    var body: some View {
        ZStack {
            AppTheme.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    header
                    inputCard
                    resultCard
                    noteCard
                }
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.l)
            }
        }
        .navigationTitle("API Health QA")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack(spacing: AppTheme.Spacing.s) {
                PulseSectionHeader("API ヘルス確認", icon: "stethoscope")
                PulseStatusBadge("DEBUG", kind: .warning)
            }
            Text("入力したベースURLの /api/health を手動で確認する開発・QA専用ツールです。リリース版には含まれません。同期やバックアップは行いません。")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Input

    private var inputCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                Text("ベースURL（この画面内のみ・保存されません）")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                TextField("https://example.test/", text: $baseURLString)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .font(.callout)
                Button {
                    runCheck()
                } label: {
                    HStack(spacing: AppTheme.Spacing.s) {
                        if isChecking { ProgressView() }
                        Text(isChecking ? "確認中…" : "確認する")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PulsePrimaryButtonStyle())
                .disabled(isChecking || baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultCard: some View {
        PulseCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                Text("結果")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: AppTheme.Spacing.s) {
                    Image(systemName: resultIcon)
                        .foregroundStyle(resultColor)
                    Text(resultText)
                        .font(.callout)
                        .foregroundStyle(AppTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var noteCard: some View {
        PulseCard {
            HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
                Image(systemName: "ladybug")
                    .foregroundStyle(AppTheme.accent)
                    .accessibilityHidden(true)
                Text("読み取り専用のGET確認のみ。トークンは送信せず、ユーザーデータも送信しません。本番URLの既定値はありません。")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func runCheck() {
        let input = baseURLString
        isChecking = true
        result = nil
        Task {
            let outcome = await APIHealthQAModel.check(baseURLString: input)
            isChecking = false
            result = outcome
        }
    }

    // MARK: - Result presentation

    private var resultText: String {
        switch result {
        case nil:                       return "未確認"
        case .notConfigured:            return "未設定（有効なベースURLを入力してください）"
        case let .healthy(version):     return "正常" + (version.map { "（version \($0)）" } ?? "")
        case let .degraded(version):    return "縮退" + (version.map { "（version \($0)）" } ?? "")
        case .disabled:                 return "通信は無効です"
        case let .failed(message):      return "エラー: \(message)"
        }
    }

    private var resultIcon: String {
        switch result {
        case .healthy:                  return "checkmark.circle.fill"
        case .degraded:                 return "exclamationmark.triangle.fill"
        case .failed, .disabled:        return "xmark.octagon.fill"
        case .notConfigured, nil:       return "questionmark.circle"
        }
    }

    private var resultColor: Color {
        switch result {
        case .healthy:                  return AppTheme.success
        case .degraded:                 return .orange
        case .failed, .disabled:        return .red
        case .notConfigured, nil:       return AppTheme.textSecondary
        }
    }
}

#Preview("API Health QA") {
    NavigationStack { APIHealthQAView() }
}
#endif
