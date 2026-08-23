//
//  AppleSignInNonce.swift
//  Pulse Cue
//
//  The nonce that ties one Sign in with Apple result to one sign-in attempt.
//
//  How it works, and why both halves are needed:
//
//    1. The app generates a random raw nonce.
//    2. It puts **SHA-256 of that nonce** on the `ASAuthorizationAppleIDRequest`.
//    3. Apple echoes the hash back inside the signed identity token.
//    4. The app sends the **raw** nonce to the PulseCue server alongside the
//       token; the server hashes it and compares.
//
//  Sending the hash to Apple and the raw value to the server is the point: a
//  captured identity token proves nothing without the raw nonce, and the
//  server spends each nonce once, so a captured request body cannot be
//  replayed for the rest of the token's lifetime.
//
//  Randomness comes from `SecRandomCopyBytes`. `Int.random` and friends are
//  not for this — a predictable nonce removes the binding entirely.
//

import CryptoKit
import Foundation
import Security

enum AppleSignInNonce {

    /// 32 bytes of CSPRNG output, hex encoded.
    ///
    /// Hex rather than base64 so the value is URL- and log-safe by
    /// construction, and 32 bytes because that is comfortably past any
    /// birthday-bound concern for a value used once.
    static func makeRawNonce(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // There is no safe fallback. A predictable nonce would silently
            // remove the replay protection the whole flow depends on, so this
            // fails loudly rather than degrading.
            fatalError("SecRandomCopyBytes failed with status \(status)")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex SHA-256 — the exact form Apple echoes and the server
    /// recomputes.
    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
