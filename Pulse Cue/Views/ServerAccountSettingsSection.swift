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

    /// Who currently owns the Google SDK's session. Injectable for tests;
    /// shared in the app, because the SDK's session is shared.
    var googleSDKSession: GoogleSDKSessionOwnership?

    private var googleSession: GoogleSDKSessionOwnership {
        googleSDKSession ?? .shared
    }

    @State private var showDeleteConfirmation = false
    @State private var isWorking = false
    @State private var deletionFailed = false
    @State private var deletionPending = false

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
        .alert("アカウントの削除を確認できませんでした", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            // Deliberately does not claim the account still exists — a lost
            // response means the server may have accepted it. It says only
            // what is true: this app could not confirm the deletion.
            Text(
                """
                削除を確認できませんでした。通信環境を確認して、もう一度お試しください。
                アカウントが削除されたかどうかは、次回のサインインで確認できます。
                """
            )
        }
        .alert("アカウントの削除を受け付けました", isPresented: $deletionPending) {
            Button("OK", role: .cancel) {}
        } message: {
            // Truthful about a 202: the request is irreversible and this
            // device is signed out, but the server has not confirmed that
            // provider revocation finished.
            Text(
                """
                削除処理は取り消せません。この端末からはサインアウトされました。
                サーバー側の処理が完了するまで少し時間がかかる場合があります。
                この端末に保存されたトレーニング記録は削除されていません。
                """
            )
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
        case .localCleanupFailed: return "要再試行"
        }
    }

    private var badgeKind: PulseStatusBadge.Kind {
        switch store.state {
        case .authenticated:      return .success
        case .unreachable:        return .warning
        case .localCleanupFailed: return .warning
        default:                  return .info
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
        case .localCleanupFailed:
            // Truthful rather than reassuring: the token may still be on this
            // device, so "signed out" would be a claim we cannot support.
            return """
                この端末のサインイン情報を削除できませんでした。\
                もう一度サインアウトをお試しください。トレーニング記録は削除されていません。
                """
        case .guest:
            return """
                サインインしていなくても、記録・ルーティン・履歴などすべての機能を利用できます。\
                トレーニング記録は現在この端末に保存されます。
                """
        case .restoring, .signingIn:
            return """
                アカウントの状態を確認しています。\
                記録・ルーティン・履歴などすべての機能はそのまま利用できます。
                """
        }
    }

    // MARK: - Actions

    private func signOut() async {
        isWorking = true
        defer { isWorking = false }
        // The local sign-out is attempted even if the server cannot be reached
        // — a user must never be stuck signed in because of a network problem.
        // But it only *counts* when the token is really gone; a failed Keychain
        // delete surfaces as `.localCleanupFailed` rather than as Guest, and
        // the section's own copy explains it. Local training data is untouched
        // either way.
        _ = await store.logout()

        // The Google SDK's own session is deliberately left alone: by existing
        // policy a PulseCue sign-out is not a Google sign-out — unlinking is
        // the action that ends that. But the ownership record is dropped, so a
        // provider flow that unwinds later cannot "clean up" on behalf of a
        // session this sign-out already ended.
        googleSession.release()
    }

    private func deleteAccount() async {
        isWorking = true
        defer { isWorking = false }
        switch await store.deleteAccount() {
        case .deleted:
            // The only outcome that means the account is actually gone.
            //
            // With no PulseCue account left, a device still signed into the
            // Google account that backed it is the ownership split we are
            // trying to avoid, so that session ends here too.
            googleSession.releaseAndSignOut()
            deletionFailed = false
            deletionPending = false
        case .pending:
            // Accepted and irreversible — the account is going away — so the
            // local Google session is ended on the same reasoning as `.deleted`.
            googleSession.releaseAndSignOut()
            // Accepted and irreversible, but the server has not finished
            // revoking at the provider. Saying "削除しました" here would claim
            // something the server has not confirmed.
            deletionFailed = false
            deletionPending = true
        case .notConfirmed, .notAttempted:
            // Neither of these proves anything about the account — a 401 looks
            // identical to a first attempt whose response was lost, and a
            // request that was never sent cannot have deleted anything. The
            // honest answer to the user is "we could not confirm it".
            deletionFailed = true
            deletionPending = false
        }
    }
}
