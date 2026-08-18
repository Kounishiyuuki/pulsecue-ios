//
//  ServerAccountSettingsSection.swift
//  Pulse Cue
//
//  The PulseCue *account* rows in Settings: server status, sign out, and
//  delete account.
//
//  Kept in its own file rather than grown inside SettingsView because the
//  copy here has to be precise, and precise copy is easier to review when it
//  is not buried in a thousand-line view.
//
//  Two things this UI must never say:
//
//    "同期済み" / "バックアップ済み" — nothing syncs yet. A user only finds
//      out that promise was false when they lose a phone.
//
//    "連携済み" on the strength of a *local* record — a `LinkedAccount` left
//      over from the local-only era means a provider was once attached to
//      this device, not that an account exists on the server. Only a
//      server-confirmed profile drives the signed-in wording.
//
//  And one distinction it must keep visible: deleting the PulseCue account is
//  not deleting this device's training data. A user who confuses the two
//  loses everything.
//

import SwiftUI

struct ServerAccountSettingsSection: View {
    @ObservedObject var store: ServerAccountStore

    @State private var showDeleteConfirmation = false
    @State private var isWorking = false
    @State private var deletionFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow

            if let failure = store.lastFailure {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.state.isAuthenticated {
                Divider().opacity(0.4)
                signOutButton
                deleteAccountButton
            }

            explanation
        }
        .confirmationDialog(
            "PulseCueアカウントを削除しますか？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("アカウントを削除", role: .destructive) {
                Task { await deleteAccount() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            // Says exactly what is destroyed and what is not. This is the one
            // place a misunderstanding is unrecoverable.
            Text(
                """
                PulseCueアカウントとサーバー上のデータを削除します。この操作は取り消せません。
                この端末に保存されたトレーニング記録は削除されません。
                """
            )
        }
        .alert("アカウントを削除できませんでした", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("通信環境を確認して、もう一度お試しください。アカウントは削除されていません。")
        }
    }

    // MARK: - Rows

    private var statusRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PulseCueアカウント")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(store.state.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            PulseStatusBadge(badgeTitle, kind: badgeKind)
        }
    }

    private var signOutButton: some View {
        Button {
            Task { await signOut() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("サインアウト")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private var deleteAccountButton: some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                Text("アカウントを削除")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .disabled(isWorking)
    }

    private var explanation: some View {
        Text(explanationText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Copy

    private var badgeTitle: String {
        switch store.state {
        case .authenticated: return "サインイン済み"
        case .unreachable:   return "オフライン"
        case .restoring:     return "確認中"
        case .signingIn:     return "処理中"
        case .guest:         return "ローカルのみ"
        case .notConfigured: return "未設定"
        }
    }

    private var badgeKind: PulseStatusBadge.Kind {
        switch store.state {
        case .authenticated: return .success
        case .unreachable:   return .warning
        default:             return .info
        }
    }

    private var explanationText: String {
        switch store.state {
        case .authenticated:
            // Truthful about scope: an account exists, sync does not.
            return """
                PulseCueアカウントにサインインしています。トレーニング記録などの端末内データは、\
                まだサーバーに同期・バックアップされていません。
                """
        case .unreachable:
            return """
                サーバーに接続できないため、アカウント状態を確認できていません。\
                サインイン情報はこの端末に保持されています。アプリはこのまま利用できます。
                """
        case .notConfigured:
            return """
                この端末のビルドではPulseCueアカウント機能を利用できません。\
                アプリの機能はこれまでどおりすべて利用できます。
                """
        case .guest, .restoring, .signingIn:
            return """
                アカウントなしでも、記録・ルーティン・履歴などすべての機能を利用できます。\
                データはこの端末内に保存されます。
                """
        }
    }

    // MARK: - Actions

    private func signOut() async {
        isWorking = true
        defer { isWorking = false }
        // The local sign-out always happens, even if the server cannot be
        // reached — a user must never be stuck signed in because of a network
        // problem. Local training data is untouched either way.
        await store.logout()
    }

    private func deleteAccount() async {
        isWorking = true
        defer { isWorking = false }
        let deleted = await store.deleteAccount()
        // Only tell the user it worked when it did. A failed deletion leaves
        // the account exactly where it was.
        deletionFailed = !deleted
    }
}
