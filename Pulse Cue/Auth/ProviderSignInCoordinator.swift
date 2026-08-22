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

/// How a sign-in ended.
enum ProviderSignInOutcome: Equatable {
    case signedIn
    /// The user backed out of the provider sheet.
    case cancelled
    /// The provider SDK failed, or returned something unusable.
    case providerFailed
    /// PulseCue refused it. See `ProviderSignInRefusal` for when.
    case refused(ProviderSignInRefusal)
}

/// Why PulseCue refused a sign-in.
///
/// These do **not** all happen at the same point, and the difference decides
/// whether there is provider-side state to clean up afterwards:
///
///   *Before the SDK* — `existingSession`, `credentialUnavailable`, `busy`,
///     `notConfigured`. No sheet opened, nothing on the device changed, and
///     there is nothing to undo.
///
///   *After the SDK succeeded* — `superseded`, `serverRefused`. The user
///     completed an authorization, so the provider's own state has already
///     moved (for Google, the device's selected account). PulseCue's session
///     does not exist, so the flow puts its provider state back.
enum ProviderSignInRefusal: Equatable {
    /// A server session is already held; sign out first. Refused pre-SDK.
    case existingSession
    /// The Keychain could not be read, so none can be ruled out. Pre-SDK.
    case credentialUnavailable
    /// Another provider sign-in is already running. Pre-SDK.
    case busy
    /// This build has no account API, or Google's config is unusable. Pre-SDK.
    case notConfigured

    /// A logout, deletion or restore retired this flow.
    ///
    /// Post-SDK: it can land while the sheet is open, during `/auth/*`, or
    /// during `/me`. Not a failure the user caused — they asked for the newer
    /// thing and got it — but the provider state this flow created is undone.
    case superseded

    /// The backend refused, or the session could not be completed. Post-SDK,
    /// with the same provider-state cleanup as `superseded`.
    case serverRefused
}

@MainActor
final class ProviderSignInCoordinator {

    private let account: ServerAccountStore
    private let apple: any AppleAuthorizing
    private let google: any GoogleAuthorizing
    private let googleConfigurationIsUsable: () -> Bool
    private let recordLink: (LinkedAccount) -> Void
    private let googleSDKSession: GoogleSDKSessionOwnership
    private let sdkInvocations: ProviderSDKInvocationLease

    init(
        account: ServerAccountStore,
        apple: any AppleAuthorizing,
        google: any GoogleAuthorizing,
        googleConfigurationIsUsable: @escaping () -> Bool,
        recordLink: @escaping (LinkedAccount) -> Void,
        googleSDKSession: GoogleSDKSessionOwnership? = nil,
        sdkInvocations: ProviderSDKInvocationLease? = nil
    ) {
        self.account = account
        self.apple = apple
        self.google = google
        self.googleConfigurationIsUsable = googleConfigurationIsUsable
        self.recordLink = recordLink
        self.googleSDKSession = googleSDKSession ?? .shared
        self.sdkInvocations = sdkInvocations ?? .shared
    }

    func signInWithApple() async -> ProviderSignInOutcome {
        await run(provider: .apple) { [apple] permit in
            switch await apple.authorize() {
            case .cancelled:
                return .cancelled
            case .failed:
                return .providerFailed
            case let .authorized(authorization):
                // Retired while Apple's sheet was open. Drop the values and
                // stop: nothing local was changed by the authorization, so
                // unlike Google there is no provider state to put back.
                // Apple's credential is not a persistent client-side session,
                // and a fake sign-out here would only invent a state change.
                guard self.account.isProviderSignInCurrent(permit) else {
                    return .refused(.superseded)
                }

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
            // Taken before `GIDSignIn` is touched and held until its callback
            // has actually been dealt with. While it is held no second Google
            // SDK call may start, which is what stops an earlier call's
            // completion from landing on top of a later, finished one.
            guard let ticket = self.sdkInvocations.acquire(.google) else {
                return .refused(.busy)
            }
            // Every abnormal exit still frees it; the normal path releases
            // explicitly below and this becomes a no-op.
            defer { self.sdkInvocations.release(ticket) }

            switch await google.authorize() {
            case .cancelled:
                return .cancelled
            case .failed:
                return .providerFailed
            case let .authorized(authorization):
                // Currency is checked *before* claiming ownership, so a stale
                // callback never registers itself as the owner of anything.
                guard self.account.isProviderSignInCurrent(permit) else {
                    // Stale, and the device's Google account has already been
                    // switched by the completion that just returned. Sign out
                    // of it here, while the lease still guarantees no newer
                    // Google flow exists to be harmed by an unowned sign-out.
                    self.googleSDKSession.signOutCurrentSession()
                    return .refused(.superseded)
                }

                // Current, so this flow owns what the SDK now holds, and is
                // responsible for putting it back if PulseCue's own sign-in
                // does not complete.
                self.googleSDKSession.claim(permit)

                // The SDK call itself is over. Releasing now lets a later
                // Google sign-in start while this one waits on the network —
                // the backend-phase race, which ownership handles rather than
                // the lease.
                self.sdkInvocations.release(ticket)

                // Every unsuccessful exit from here runs the owner-checked
                // cleanup, including the ones that suspend first: the flow can
                // go stale during `/auth/google` or during `/me`. `committed`
                // is set only once a PulseCue session genuinely exists.
                var committed = false
                defer {
                    if !committed {
                        self.googleSDKSession.signOutIfOwned(by: permit)
                    }
                }

                let signedIn = await self.account.signInWithGoogle(
                    permit: permit,
                    idToken: authorization.idToken
                )
                guard signedIn else {
                    // Distinguishable only by asking: the store returns the
                    // same `false` whether the server said no or a logout
                    // retired this flow mid-request.
                    return .refused(
                        self.account.isProviderSignInCurrent(permit)
                            ? .serverRefused
                            : .superseded
                    )
                }

                self.recordLink(
                    LinkedAccount(
                        provider: .google,
                        userIdentifier: authorization.providerUserID,
                        displayName: authorization.displayName,
                        email: authorization.email
                    )
                )
                // A PulseCue session now exists and is persisted, so this
                // flow's Google session is the one the app wants. Ownership
                // stays with the permit even after it is released below —
                // that is what stops an older flow claiming it later.
                committed = true
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
