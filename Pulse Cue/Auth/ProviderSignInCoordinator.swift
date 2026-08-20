//
//  ProviderSignInCoordinator.swift
//  Pulse Cue
//
//  The one place a provider sign-in may start.
//
//  Why this exists as a type rather than a few lines in `LoginView`: the
//  provider SDKs have side effects of their own, and they land the moment the
//  sheet completes — before PulseCue gets a say. Google's is the clear case.
//  `GIDSignIn` switches the device's *locally selected Google account* as soon
//  as the user picks one, so a sign-in PulseCue would later refuse still
//  leaves the phone pointing at a different Google account than the PulseCue
//  session it is holding. Refusing after the fact is too late; the SDK must
//  not be started at all.
//
//  So the order is fixed here, and there is no other route to the SDKs:
//
//      permit  →  provider SDK  →  backend exchange
//
//  A `LoginView` button cannot skip the permit, because it does not know how
//  to reach the SDKs without going through this type. Disabling a button is a
//  courtesy; this is the enforcement.
//
//  The SDK calls sit behind narrow protocols so a test can assert the exact
//  number of times they were invoked — which is the only way to prove "the
//  sheet never opened" rather than "the sign-in eventually failed".
//

import Foundation

/// What a provider authorization produced.
///
/// Deliberately plain values. The provider credential objects are live SDK
/// types; copying out what the backend needs means they are released when the
/// callback returns rather than held across two network round trips.
struct AppleAuthorization: Equatable {
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
    /// Apple's stable, app-scoped identifier.
    ///
    /// For the **local** `LinkedAccount` record only. It is never sent to the
    /// backend as identity — the server reads the subject from the signature
    /// it verified, and `AppleSignInRequest` has no field for it.
    let providerUserID: String
    let displayName: String?
    let email: String?
}

struct GoogleAuthorization: Equatable {
    let idToken: String
    /// Local record only, exactly as above.
    let providerUserID: String
    let displayName: String?
    let email: String?
}

enum ProviderAuthorizationOutcome<Value> {
    case authorized(Value)
    /// The user dismissed the sheet. Not an error, and not a state change.
    case cancelled
    /// The SDK failed, or returned something unusable.
    case failed
}

@MainActor
protocol AppleAuthorizing: AnyObject {
    func authorize() async -> ProviderAuthorizationOutcome<AppleAuthorization>
}

@MainActor
protocol GoogleAuthorizing: AnyObject {
    func authorize() async -> ProviderAuthorizationOutcome<GoogleAuthorization>
}

/// Why a sign-in did not start or did not finish.
enum ProviderSignInOutcome: Equatable {
    case signedIn
    /// The user backed out of the provider sheet.
    case cancelled
    /// The provider SDK failed.
    case providerFailed
    /// Refused before the SDK was touched.
    case refused(ProviderSignInRefusal)
}

enum ProviderSignInRefusal: Equatable {
    /// A server session is already held; sign out first.
    case existingSession
    /// The Keychain could not be read, so none can be ruled out.
    case credentialUnavailable
    /// Another provider sign-in is already running.
    case busy
    /// This build has no account API, or Google's config is unusable.
    case notConfigured
    /// The backend refused, or the session could not be completed.
    case serverRefused
}

@MainActor
final class ProviderSignInCoordinator {

    private let account: ServerAccountStore
    private let apple: any AppleAuthorizing
    private let google: any GoogleAuthorizing
    private let googleConfigurationIsUsable: () -> Bool
    private let recordLink: (LinkedAccount) -> Void

    init(
        account: ServerAccountStore,
        apple: any AppleAuthorizing,
        google: any GoogleAuthorizing,
        googleConfigurationIsUsable: @escaping () -> Bool,
        recordLink: @escaping (LinkedAccount) -> Void
    ) {
        self.account = account
        self.apple = apple
        self.google = google
        self.googleConfigurationIsUsable = googleConfigurationIsUsable
        self.recordLink = recordLink
    }

    func signInWithApple() async -> ProviderSignInOutcome {
        await run(provider: .apple) { [apple] permit in
            switch await apple.authorize() {
            case .cancelled:
                return .cancelled
            case .failed:
                return .providerFailed
            case let .authorized(authorization):
                let signedIn = await self.account.signInWithApple(
                    permit: permit,
                    identityToken: authorization.identityToken,
                    authorizationCode: authorization.authorizationCode,
                    rawNonce: authorization.rawNonce
                )
                guard signedIn else { return .refused(.serverRefused) }

                // The local link follows the server, never leads it. Reaching
                // here means the session was verified and persisted.
                self.recordLink(
                    LinkedAccount(
                        provider: .apple,
                        userIdentifier: authorization.providerUserID,
                        displayName: authorization.displayName,
                        email: authorization.email
                    )
                )
                return .signedIn
            }
        }
    }

    func signInWithGoogle() async -> ProviderSignInOutcome {
        // Checked before the permit so a misconfigured build does not take a
        // reservation it cannot use.
        guard googleConfigurationIsUsable() else {
            return .refused(.notConfigured)
        }

        return await run(provider: .google) { [google] permit in
            switch await google.authorize() {
            case .cancelled:
                return .cancelled
            case .failed:
                return .providerFailed
            case let .authorized(authorization):
                let signedIn = await self.account.signInWithGoogle(
                    permit: permit,
                    idToken: authorization.idToken
                )
                guard signedIn else { return .refused(.serverRefused) }

                self.recordLink(
                    LinkedAccount(
                        provider: .google,
                        userIdentifier: authorization.providerUserID,
                        displayName: authorization.displayName,
                        email: authorization.email
                    )
                )
                return .signedIn
            }
        }
    }

    /// Takes the permit, runs the flow, and always gives the permit back.
    ///
    /// The `defer` is the important part: a permit leaked on a cancellation or
    /// an SDK error would leave the app permanently `busy` and unable to sign
    /// in at all — a worse bug than the one the reservation prevents.
    private func run(
        provider: AuthProviderKind,
        _ body: (ProviderSignInPermit) async -> ProviderSignInOutcome
    ) async -> ProviderSignInOutcome {
        switch account.prepareProviderSignIn(provider: provider) {
        case .existingSession:
            return .refused(.existingSession)
        case .credentialUnavailable:
            return .refused(.credentialUnavailable)
        case .busy:
            return .refused(.busy)
        case .notConfigured:
            return .refused(.notConfigured)
        case let .allowed(permit):
            defer { account.finishProviderSignIn(permit) }
            return await body(permit)
        }
    }
}
