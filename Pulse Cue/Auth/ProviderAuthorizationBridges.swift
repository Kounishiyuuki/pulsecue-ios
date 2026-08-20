//
//  ProviderAuthorizationBridges.swift
//  Pulse Cue
//
//  The real Apple and Google SDK calls, behind the narrow protocols
//  `ProviderSignInCoordinator` drives.
//
//  Everything SDK-specific lives here and nowhere else, which is what makes
//  "the sheet never opened" a testable claim: a test substitutes a bridge and
//  counts invocations, while production keeps the official SDKs untouched.
//
//  Both bridges extract plain values before returning. The provider credential
//  objects are live SDK types, and holding one across the backend exchange
//  would keep it — and the token data hanging off it — alive far longer than
//  the flow needs.
//

import AuthenticationServices
import Foundation
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// MARK: - Apple

/// Runs Sign in with Apple through `ASAuthorizationController`.
///
/// Presented from here rather than from a `SignInWithAppleButton`, because the
/// button starts the authorization the instant it is tapped — before any
/// Keychain check could run. Driving the controller directly is what lets the
/// permit come first.
@MainActor
final class AppleAuthorizationBridge: NSObject, AppleAuthorizing {

    private var continuation: CheckedContinuation<
        ProviderAuthorizationOutcome<AppleAuthorization>, Never
    >?
    private var rawNonce: String?
    /// Held only for the lifetime of one authorization.
    private var controller: ASAuthorizationController?

    func authorize() async -> ProviderAuthorizationOutcome<AppleAuthorization> {
        // A second concurrent authorization would overwrite the continuation
        // and strand the first. The coordinator's permit already prevents it;
        // this refuses rather than relying on that.
        guard continuation == nil else { return .failed }

        // Apple receives sha256(rawNonce) and echoes it inside the signed
        // identity token; the server receives the raw value and recomputes the
        // hash. That is what ties the token to this attempt.
        let raw = AppleSignInNonce.makeRawNonce()
        rawNonce = raw

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleSignInNonce.sha256Hex(raw)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ outcome: ProviderAuthorizationOutcome<AppleAuthorization>) {
        let pending = continuation
        continuation = nil
        controller = nil
        rawNonce = nil
        pending?.resume(returning: outcome)
    }
}

extension AppleAuthorizationBridge: ASAuthorizationControllerDelegate {

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let rawNonce,
              let identityToken = credential.identityToken
                .flatMap({ String(data: $0, encoding: .utf8) }),
              // Required, not best-effort: without it the server cannot obtain
              // the refresh token it needs to revoke at account deletion, and
              // the code cannot be re-requested later.
              let authorizationCode = credential.authorizationCode
                .flatMap({ String(data: $0, encoding: .utf8) })
        else {
            finish(.failed)
            return
        }

        let result = AppleSignInResult(
            nameComponents: credential.fullName,
            email: credential.email
        )
        // Plain values only; the credential is released when this returns.
        finish(.authorized(
            AppleAuthorization(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                rawNonce: rawNonce,
                providerUserID: credential.user,
                displayName: result.displayName,
                email: result.email
            )
        ))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        finish(cancelled ? .cancelled : .failed)
    }
}

extension AppleAuthorizationBridge: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        ProviderPresentation.keyWindow() ?? ASPresentationAnchor()
    }
}

// MARK: - Google

/// Runs Google Sign-In through `GIDSignIn`.
///
/// Nothing here starts until the coordinator has a permit. That matters more
/// for Google than for Apple: the SDK switches the device's locally selected
/// account the moment the sheet completes, so starting one we would later
/// refuse leaves the phone pointing at a different Google account than the
/// PulseCue session it holds.
@MainActor
final class GoogleAuthorizationBridge: GoogleAuthorizing {

    func authorize() async -> ProviderAuthorizationOutcome<GoogleAuthorization> {
        #if canImport(GoogleSignIn)
        guard let presenter = ProviderPresentation.topViewController() else {
            return .failed
        }

        return await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                if let error {
                    let cancelled = (error as NSError).code == GIDSignInError.canceled.rawValue
                    continuation.resume(returning: cancelled ? .cancelled : .failed)
                    return
                }
                guard let user = result?.user,
                      let userID = user.userID,
                      // The ID token is the only thing the backend accepts as
                      // identity. The access token, refresh token and
                      // serverAuthCode are deliberately not read.
                      let idToken = user.idToken?.tokenString
                else {
                    continuation.resume(returning: .failed)
                    return
                }

                let profile = GoogleSignInResult(
                    displayName: user.profile?.name,
                    email: user.profile?.email
                )
                continuation.resume(returning: .authorized(
                    GoogleAuthorization(
                        idToken: idToken,
                        providerUserID: userID,
                        displayName: profile.displayName,
                        email: profile.email
                    )
                ))
            }
        }
        #else
        // SDK unavailable at build time — treated as unusable, never as a
        // silent success.
        return .failed
        #endif
    }
}

// MARK: - Presentation

enum ProviderPresentation {

    static func windowScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
    }

    static func keyWindow() -> UIWindow? {
        windowScene()?.keyWindow
    }

    /// The top-most view controller, for presenting a provider sheet from.
    static func topViewController() -> UIViewController? {
        guard var top = keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}
