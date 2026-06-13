//
//  GoogleSignInConfig.swift
//  Pulse Cue
//
//  Reads and validates the (non-secret) Google iOS OAuth client ID from the
//  app's Info.plist so the UI can decide whether real Google Sign-In is
//  actually configured yet.
//
//  PulseCue ships a documented *placeholder* `GIDClientID` until a real Google
//  Cloud OAuth iOS client exists for the bundle. While the placeholder is in
//  place, `isConfigured` is false and the Google button must NOT start a real
//  sign-in or fabricate a signed-in state. Replacing the two Info.plist values
//  (`GIDClientID` + the reversed-client-ID URL scheme) with the real ones is
//  all that is needed to enable real Google Sign-In — no code change.
//
//  Foundation only — no GoogleSignIn dependency, so it is fully unit-testable.
//

import Foundation

struct GoogleSignInConfig: Equatable {

    /// The documented placeholder shipped in Info.plist until a real client ID
    /// is created. Kept in sync with `Pulse Cue/Info.plist`.
    static let placeholderClientID = "YOUR_IOS_CLIENT_ID.apps.googleusercontent.com"

    /// The configured client ID (already trimmed; nil when missing/blank).
    let clientID: String?

    init(clientID: String?) {
        self.clientID = GoogleSignInConfig.normalized(clientID)
    }

    /// Reads `GIDClientID` from the main bundle's Info.plist.
    static func fromMainBundle() -> GoogleSignInConfig {
        GoogleSignInConfig(clientID: Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String)
    }

    /// True only when a real-looking iOS client ID is present — i.e. not
    /// missing, not blank, not the documented placeholder, and shaped like a
    /// Google iOS client ID. Used to gate the real sign-in flow.
    var isConfigured: Bool {
        guard let clientID else { return false }
        guard clientID != GoogleSignInConfig.placeholderClientID else { return false }
        guard !clientID.contains("YOUR_IOS_CLIENT_ID") else { return false }
        return clientID.hasSuffix(".apps.googleusercontent.com")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
