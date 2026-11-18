//
//  AccountSettingsSection.swift
//  Pulse Cue
//
//  アカウント — sign-in, the linked provider, the server account, deletion.
//
//  Two separate things are on display here and they are not the same question:
//  the **local provider link** (an Apple or Google identity attached to this
//  device's profile) and the **PulseCue server account** owned by
//  `ServerAccountStore`. A link is not an account.
//
//  A server session token *is* persisted, in the Keychain. What has not
//  changed: nothing gates app usage. Signing in is optional, and every local
//  feature works without it.
//
//  The login sheet is presented from here rather than from the settings shell.
//  It belongs to this section alone, and hoisting its `@State` up to a screen
//  that also renders height steppers is how a shell accumulates other
//  sections' business.
//

import SwiftData
import SwiftUI

struct AccountSettingsSection: View {
    @EnvironmentObject private var authSession: AuthSessionStore
    @EnvironmentObject private var serverAccount: ServerAccountStore
    @Environment(\.modelContext) private var modelContext

    @State private var showLoginSheet = false

    var body: some View {
        SettingsChrome.glassCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsChrome.sectionHeader(icon: "person.crop.circle", title: "アカウント")

                // The PulseCue server account: the one place that says whether
                // this device is signed in (see `AccountSettingsPresentation`).
                ServerAccountSettingsSection(
                    store: serverAccount,
                    authSession: authSession,
                    localDataCleanup: AccountLocalDataCleanup(container: modelContext.container, mainContext: modelContext)
                )

                // The local provider link, as its own fact and only when there
                // is one. A link means a provider was attached to this device,
                // never that a server account exists.
                if let localLinkLabel = presentation.localLinkLabel {
                    Divider().opacity(0.4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("この端末の連携")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(localLinkLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Driven by the server account, the source of truth for
                // "signed in": once a session is held, the section above shows
                // it with サインアウト, and a second sign-in would be refused.
                if presentation.showsSignInEntry {
                    Button {
                        showLoginSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ログイン・アカウント設定")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("ゲストのまま使えます。Apple・Googleでサインインすることもできます。トレーニング記録は現在この端末に保存されます。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // 「プロフィールとジムの設定」 used to sit here. It was not a
                // profile screen: it registered gyms and opened MyGymHomeView,
                // so Account — authentication, sync and deletion — was a route
                // into gym management. Body fields live in 体と目標; gyms live
                // under トレーニング → その他の機能, and only there.

                if presentation.showsLocalUnlinkAction {
                    Divider().opacity(0.4)
                    Button(role: .destructive) {
                        authSession.unlinkAccount()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link.badge.plus")
                            Text("連携を解除")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }

                Divider().opacity(0.4)

                // Says exactly what the app does, which is now two different
                // things. When a server session is held a PulseCue account
                // really does exist, so the old blanket
                // 「アカウントは作成されません」 would be a false statement to
                // show that user. Neither wording promises sync: nothing syncs
                // yet in either case, and saying otherwise is the kind of
                // promise someone only discovers is false after losing a phone.
                Text(localLinkFootnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView(authSession: authSession, serverAccount: serverAccount, showsCloseButton: true)
        }
    }

    private var presentation: AccountSettingsPresentation {
        AccountSettingsPresentation(serverState: serverAccount.state, linkedProvider: authSession.session?.provider)
    }

    /// The footnote under the local link card.
    ///
    /// Keyed to the *server* state, and deliberately not a two-way split. The
    /// distinction that has to survive here is between "there is no account"
    /// and "we cannot tell right now" — collapsing those is how a UI ends up
    /// telling someone their account does not exist because their train went
    /// into a tunnel.
    ///
    /// The local link is a separate fact and is stated separately: it lives on
    /// this device either way, and it never implies a server account.
    private var localLinkFootnote: String {
        let base = "Apple・Googleとの連携はこの端末内のプロフィールに保存されます。"
        let localData = "連携を解除しても、トレーニング記録などの端末内データは削除されません。"

        switch serverAccount.state {
        case .authenticated:
            // An account demonstrably exists, so promising the opposite would
            // be false. Sync still does not, and is not implied.
            return base
                + "PulseCueアカウントは作成済みです（アカウントの削除は「アカウント」セクションから行えます）。"
                + "トレーニング記録などの端末内データは、まだ同期・バックアップされません。"
                + localData

        case .guest:
            // Guest is a fact about *this device* — not signed in — and not a
            // fact about the server. A PulseCue account may well exist and be
            // reachable from another device, so "アカウントは作成されず" would
            // be asserting something this app has no way to know.
            return base
                + "現在この端末ではPulseCueアカウントにサインインしていません。"
                + "データが別端末と同期・バックアップされることはありません。"
                + localData

        case .notConfigured:
            // The only branch that can truthfully say no account is created:
            // this build has no account API to create one with.
            return base
                + "このビルドではPulseCueアカウントは作成されず、データが別端末と同期・バックアップされることはありません。"
                + localData

        case .unresolved, .restoring, .signingIn, .unreachable:
            // Not "no account" — unknown. The device may well hold a session
            // that simply could not be confirmed.
            return base
                + "PulseCueアカウントの状態は現在確認できません。"
                + "いずれの場合も、データが別端末と同期・バックアップされることはありません。"
                + localData

        case .localCleanupFailed:
            // Sign-out did not finish locally: a credential may still be on
            // the device, so neither "signed out" nor "no account" is true.
            return base
                + "サインアウトが完了しておらず、この端末にサインイン情報が残っている可能性があります。"
                + "データが別端末と同期・バックアップされることはありません。"
                + localData
        }
    }
}

/// What the account section shows, derived from the two stores without adding
/// state of its own.
///
/// Whether this device is signed in comes from `ServerAccountState` alone —
/// `ServerAccountSettingsSection` states it, with its own per-state badge. The
/// local provider link (`AuthSessionStore`) is a different fact: which Apple or
/// Google identity was attached here. It used to sit at the top as
/// 「現在の利用状態」 with a fixed 「この端末のみ」 badge, which read as the
/// sign-in state and contradicted a server sign-in. It is now shown only when a
/// link exists, labelled as a link, with no badge.
struct AccountSettingsPresentation: Equatable {
    let serverState: ServerAccountState
    let linkedProvider: AuthProviderKind?

    var showsSignInEntry: Bool { serverState.offersSignIn }

    /// 「連携を解除」: forgets only the local link, never the server session.
    ///
    /// Offered only for a stale link — one left on a device that holds no
    /// server session and has no sign-in in flight (guest, or a build with no
    /// account API). While a session may be held (authenticated, unreachable,
    /// restoring, localCleanupFailed) the way out is サインアウト, which ends
    /// the session and then clears the link itself; dropping just the link
    /// there would leave the user signed in with nothing visibly changed.
    var showsLocalUnlinkAction: Bool {
        localLinkLabel != nil && !serverState.holdsSession && serverState != .signingIn
    }

    /// nil when nothing is linked: the row is then not drawn at all.
    var localLinkLabel: String? {
        switch linkedProvider {
        case .apple:  return "Appleと連携済み"
        case .google: return "Googleと連携済み"
        case .guest, nil: return nil
        }
    }
}
