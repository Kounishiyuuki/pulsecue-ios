//
//  ServerAccountState.swift
//  Pulse Cue
//
//  Whether there is a PulseCue *server* account behind this device, which is
//  a different question from whether a provider identity is linked locally.
//
//  Those two used to be the same thing because there was no server. They are
//  not the same any more, and conflating them is the specific mistake this
//  type exists to prevent: a `LinkedAccount` left over from the local-only
//  era means a provider was once attached to this device. It does **not**
//  mean an account exists on the server, and the UI must not say it does.
//
//  The offline case is the other thing worth being careful about. A valid
//  session plus a flaky network is not a signed-out user. Dropping the
//  session there would sign someone out for walking into a lift, so
//  `.unreachable` keeps the token and says plainly that the account state is
//  unknown right now. Only an actual `401` clears the Keychain.
//

import Foundation

enum ServerAccountState: Equatable {

    /// No server session. Every local feature works; this is not an error.
    case guest

    /// Checking a stored session at launch.
    case restoring

    /// A sign-in is in flight.
    case signingIn

    /// The server confirmed this session.
    case authenticated(ServerAccountProfile)

    /// A session exists but the server could not be reached to confirm it.
    ///
    /// The token is deliberately kept. The app is fully usable; only account
    /// features wait.
    case unreachable

    /// The account API is not configured in this build. Not a failure the
    /// user caused, and not something to retry.
    case notConfigured

    /// Signed out server-side, but the token could not be removed from the
    /// Keychain — so it may still be on disk.
    ///
    /// Deliberately not `.guest`. Guest means "there is definitely no session
    /// token", and a failed delete cannot promise that: the next launch would
    /// read the leftover token back. Saying Guest here would be a claim the
    /// device cannot support.
    case localCleanupFailed

    /// True only when the server has confirmed an active account.
    ///
    /// Nothing else may drive "Appleと連携済み" — not a stored token, not a
    /// local `LinkedAccount`.
    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var profile: ServerAccountProfile? {
        if case let .authenticated(profile) = self { return profile }
        return nil
    }

    /// Whether a session token may be on the device right now.
    ///
    /// `localCleanupFailed` counts: the whole point of that state is that a
    /// token might still be on disk.
    var holdsSession: Bool {
        switch self {
        case .authenticated, .unreachable, .restoring, .localCleanupFailed:
            return true
        case .guest, .signingIn, .notConfigured:
            return false
        }
    }

    /// A truthful Japanese status line.
    ///
    /// None of these say "同期済み" or "バックアップ済み". Nothing syncs yet,
    /// and claiming otherwise would be the kind of promise a user only
    /// discovers is false when they lose a phone.
    var statusLabel: String {
        switch self {
        case .guest:
            return "ゲスト（この端末に保存）"
        case .restoring:
            return "アカウントを確認中…"
        case .signingIn:
            return "サインイン中…"
        case let .authenticated(profile):
            let providers = profile.linkedProviders
                .map { $0.provider == "apple" ? "Apple" : "Google" }
                .sorted()
                .joined(separator: "・")
            return providers.isEmpty
                ? "PulseCueアカウントにサインイン済み"
                : "\(providers)でサインイン済み"
        case .unreachable:
            return "オフラインのためアカウント状態を確認できません"
        case .notConfigured:
            return "アカウント機能は未設定です"
        case .localCleanupFailed:
            return "サインアウトは完了していません"
        }
    }
}

/// Why a sign-in or account action did not succeed, in terms the UI can show.
enum ServerAccountFailure: Equatable {
    /// The provider gave us something the server needs and we did not get it.
    case missingProviderCredential
    /// The server said the credential was not good.
    case rejected
    /// Network, timeout, or the server is having a bad time.
    case unreachable
    /// This build has no API URL, or Google's server client ID is missing.
    case notConfigured
    /// The Keychain refused to store the session, so signing in cannot stick.
    case couldNotStoreSession
    /// The Keychain refused to remove the session, so it may still be on disk.
    case couldNotClearSession
    /// The Keychain could not be read, so no authenticated request is possible.
    case credentialUnavailable
    /// A server session is already held on this device; sign out first.
    case existingSessionHeld

    var message: String {
        switch self {
        case .missingProviderCredential:
            return "サインイン情報を取得できませんでした。もう一度お試しください。"
        case .rejected:
            return "サインインできませんでした。もう一度お試しください。"
        case .unreachable:
            return "接続できませんでした。通信環境を確認してください。"
        case .notConfigured:
            return "この端末ではアカウント機能をまだ利用できません。"
        case .couldNotStoreSession:
            return "この端末にサインイン情報を保存できませんでした。"
        case .couldNotClearSession:
            return "この端末のサインイン情報を削除できませんでした。もう一度お試しください。"
        case .credentialUnavailable:
            return "この端末のサインイン情報を読み取れませんでした。しばらくしてからお試しください。"
        case .existingSessionHeld:
            return "すでにサインインしています。別のアカウントでサインインするには、先にサインアウトしてください。"
        }
    }
}
