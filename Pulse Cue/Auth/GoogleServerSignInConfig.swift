//
//  GoogleServerSignInConfig.swift
//  Pulse Cue
//
//  The *second* Google client ID — the one the backend checks.
//
//  Google Cloud issues two OAuth clients for this arrangement and they are
//  easy to confuse, so, explicitly:
//
//    iOS client ID   → `GIDClientID` in Info.plist, and the reversed-client-ID
//                      URL scheme. Identifies the app to Google. NEVER appears
//                      in the ID token's `aud`.
//
//    Web/server      → `GIDServerClientID` in Info.plist, and `GOOGLE_AUDIENCE`
//    client ID         on the backend. When the app sets this, Google mints
//                      the ID token with `aud` set to it, which is what the
//                      backend verifies against.
//
//  So this is a *separate* setting from `GoogleSignInConfig`, not a rename of
//  it. The existing iOS client ID and its URL scheme stay exactly as they are,
//  and the server client ID gets **no** reversed URL scheme — it is not an
//  app identity and nothing redirects to it.
//
//  While it is unconfigured, Google sign-in must not claim to have created a
//  PulseCue account. There is no fake success here: the flow reports that the
//  server side is unavailable, and the app stays honest about it.
//

import Foundation

struct GoogleServerSignInConfig: Equatable {

    /// The documented placeholder shipped in Info.plist until a real Web
    /// application OAuth client exists. Kept in sync with `Info.plist`.
    static let placeholderServerClientID =
        "YOUR_WEB_SERVER_CLIENT_ID.apps.googleusercontent.com"

    /// The configured server client ID (trimmed; nil when missing/blank).
    let serverClientID: String?

    init(serverClientID: String?) {
        self.serverClientID = GoogleServerSignInConfig.normalized(serverClientID)
    }

    /// Reads `GIDServerClientID` from the main bundle's Info.plist.
    static func fromMainBundle(bundle: Bundle = .main) -> GoogleServerSignInConfig {
        GoogleServerSignInConfig(
            serverClientID: bundle.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        )
    }

    /// True only when a real-looking Web/server client ID is present.
    var isConfigured: Bool {
        guard let serverClientID else { return false }
        guard serverClientID != GoogleServerSignInConfig.placeholderServerClientID else {
            return false
        }
        guard !serverClientID.contains("YOUR_WEB_SERVER_CLIENT_ID") else { return false }
        return serverClientID.hasSuffix(".apps.googleusercontent.com")
    }

    /// Whether this value is the iOS client ID by mistake.
    ///
    /// Both are `...apps.googleusercontent.com`, so shape alone cannot tell
    /// them apart — but they must never be equal, and that *is* checkable.
    /// Getting it wrong fails closed (the backend rejects every token), but
    /// the failure looks like "sign-in is broken", which is a bad afternoon
    /// for whoever debugs it.
    func isDistinct(from iosClientID: String?) -> Bool {
        guard let serverClientID, let iosClientID else { return true }
        return serverClientID != iosClientID
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
