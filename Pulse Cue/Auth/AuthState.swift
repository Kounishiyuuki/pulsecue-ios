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

/// Identifies which (future) sign-in path a session came from.
///
/// `apple` / `google` are placeholders only in this phase — the real
/// providers are mock implementations (`MockAppleAuthProvider` /
/// `MockGoogleAuthProvider`) that perform no network or SDK calls.
enum AuthProviderKind: String, Codable, CaseIterable, Identifiable {
    case guest
    case apple
    case google

    var id: String { rawValue }

    /// Short Japanese label for the current usage state, used by the
    /// read-only Settings status row. Apple / Google read as "準備中"
    /// because no real sign-in exists yet.
    var statusLabel: String {
        switch self {
        case .guest:  return "ゲスト（ローカル利用）"
        case .apple:  return "Apple でサインイン（準備中）"
        case .google: return "Google でサインイン（準備中）"
        }
    }
}

/// Lightweight, local auth state. Deliberately minimal:
///   - `signedOut` — no account context (still fully usable locally).
///   - `guest`     — explicit local-only usage (the current default).
///   - `signedIn`  — carries only non-sensitive display metadata.
///
/// There is intentionally no token / credential / session-persistence case;
/// real account binding is deferred to a later phase.
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
