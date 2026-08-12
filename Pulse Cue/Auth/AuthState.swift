//
//  AuthState.swift
//  Pulse Cue
//
//  Local auth *shell* state for the Pre-API readiness phase. This is the
//  smallest model that can support future Guest / Apple / Google login work
//  (PR #113–#115) without introducing any real authentication today.
//
//  Nothing here performs real auth, stores tokens, or gates app usage. The
//  app remains fully usable in guest / local-only mode; this type only
//  describes which mode the (future) account layer is in.
//

import Foundation

/// Which provider identity is linked to this device's profile, if any.
///
/// `apple` / `google` are real sign-ins through the system and SDK UI. They
/// link a provider identity locally — there is no PulseCue account and no
/// server behind them.
enum AuthProviderKind: String, Codable, CaseIterable, Identifiable {
    case guest
    case apple
    case google

    var id: String { rawValue }

    /// Short Japanese label for the Settings status row. The wording says
    /// "連携" rather than "サインイン済み" because that is literally what
    /// happened: an identity was attached to this device's profile. Nothing
    /// was created on a server and nothing syncs.
    var statusLabel: String {
        switch self {
        case .guest:  return "ゲスト（ローカル利用）"
        case .apple:  return "Appleと連携済み（この端末のみ）"
        case .google: return "Googleと連携済み（この端末のみ）"
        }
    }
}

/// Lightweight, local auth state. Deliberately minimal:
///   - `signedOut` — no account context (still fully usable locally).
///   - `guest`     — explicit local-only usage (the current default).
///   - `signedIn`  — carries only non-sensitive display metadata.
///
/// There is intentionally no token / credential case: the provider SDKs own
/// credentials, and what PulseCue persists is only the link record in
/// `LinkedAccount`.
enum AuthState: Equatable {
    case signedOut
    case guest
    case signedIn(AuthSession)

    /// The attached session, if any. `nil` for `signedOut` / `guest`.
    var session: AuthSession? {
        if case let .signedIn(session) = self { return session }
        return nil
    }

    /// Japanese label describing the current usage state for display only.
    var statusLabel: String {
        switch self {
        case .signedOut:           return "未ログイン"
        case .guest:               return AuthProviderKind.guest.statusLabel
        case let .signedIn(session): return session.provider.statusLabel
        }
    }
}
