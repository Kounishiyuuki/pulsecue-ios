//
//  ServerAccountStore.swift
//  Pulse Cue
//
//  The PulseCue server account: restore at launch, sign in, sign out, delete.
//
//  Five rules run through everything here.
//
//  **Only the server decides who you are.** The app hands over a signed
//  provider token and nothing else. `ASAuthorizationAppleIDCredential.user`,
//  `GIDGoogleUser.userID`, emails and display names are never sent as
//  identity — the server takes the subject out of the signature it verified.
//  There is no field on `AppleSignInRequest` or `GoogleSignInRequest` for
//  them, so it is not a discipline anyone has to remember.
//
//  **A network failure is not a sign-out.** Only an actual rejection clears
//  the Keychain. A timeout leaves the session exactly where it was and the
//  state becomes `.unreachable`, because the alternative signs people out for
//  riding a train.
//
//  **Once the server issues a session token, this app owns its lifecycle.**
//  From that moment there are exactly two acceptable endings: it is persisted
//  as the current session, or it is handed back with a best-effort logout.
//  No path simply drops it — a dropped token is a live 60-day session that
//  nobody can see and nobody can revoke.
//
//  **Only the newest operation may write state.** `@MainActor` serialises
//  *steps*, not *operations*: restore, sign-in, logout and deletion all
//  suspend across `await`, so a slow response from an abandoned operation can
//  land after a newer one finished. Every authoritative operation therefore
//  takes a generation and re-checks it after each `await`, before touching
//  state or the Keychain.
//
//  **One session at a time.** While a server session is stored on this
//  device, a new Apple/Google sign-in is refused before the provider SDK or
//  the backend is touched. Signing in again would mint a second server
//  session and overwrite the first in the Keychain, leaving the original
//  valid on the server with nothing here tracking it — an orphan nobody can
//  revoke. Account switching is a real feature with real edge cases; refusing
//  is the small, honest version of it, and explicit logout is the only thing
//  that ends a session's life.
//
//  **Guest is untouched.** Everything below is additive. With no API
//  configured, no session, or no network, every local feature works exactly
//  as it did, and local training data is never deleted by anything in this
//  file — not by logout, not by account deletion.
//

import Foundation
import Combine

/// What a deletion attempt achieved, as far as the app can truthfully say.
enum AccountDeletionResult: Equatable {
    /// The server confirmed the account is gone (`200`).
    case deleted
    /// Accepted and irreversible, provider revocation unfinished (`202`).
    case pending
    /// The request reached the server and confirmed nothing.
    case notConfirmed(NotConfirmedReason)
    /// No request was made, so nothing can be said about the account.
    case notAttempted(NotAttemptedReason)

    enum NotConfirmedReason: Equatable {
        /// `401`/`403`: the session was refused.
        ///
        /// This says nothing about the account — and it is exactly what a
        /// *successful* first attempt looks like when its response is lost and
        /// the client retries with a token the server has already revoked. The
        /// two are indistinguishable from here, so claiming deletion would be a
        /// guess dressed as a fact.
        case authenticationRequired
        /// `5xx`, timeout, offline. The server may or may not have accepted it.
        case unreachable
    }

    enum NotAttemptedReason: Equatable {
        /// The Keychain could not be read, so no authenticated request exists.
        case credentialUnavailable
        /// No session token on the device. Not the same as "already deleted".
        case notSignedIn
        /// A newer operation superseded this one.
        case superseded
    }
}

/// What a logout achieved locally.
enum LogoutResult: Equatable {
    /// The token is definitely gone from this device.
    case signedOut
    /// The server side may be done, but the token could not be removed here.
    case localCleanupFailed
}

/// Permission to run one provider sign-in, start to finish.
///
/// Held from before the provider SDK is invoked until the flow ends, however
/// it ends. Its existence is what stops a second provider flow starting
/// alongside the first.
struct ProviderSignInPermit: Equatable {
    fileprivate let id: UInt64
    let provider: AuthProviderKind

    #if DEBUG
    /// A permit the store will always reject.
    ///
    /// For tests that drive the store directly while asserting a *refusal* —
    /// they still have to pass something, and passing a forgeable-looking
    /// valid permit would defeat the check being tested. Debug-only, so
    /// production has no way to mint one.
    static func rejectedPlaceholder(
        provider: AuthProviderKind
    ) -> ProviderSignInPermit {
        ProviderSignInPermit(id: .max, provider: provider)
    }
    #endif
}

/// The answer to "may I start a provider sign-in right now?".
enum ProviderSignInPreparation: Equatable {
    /// Go ahead — and only now may the provider SDK be touched.
    case allowed(ProviderSignInPermit)
    /// A server session is already held on this device. Sign out first.
    case existingSession
    /// The Keychain could not be read, so we cannot prove none is held.
    case credentialUnavailable
    /// Another provider sign-in is already under way.
    case busy
    /// The account API is not configured in this build.
    case notConfigured
}

@MainActor
final class ServerAccountStore: ObservableObject {

    @Published private(set) var state: ServerAccountState
    /// The most recent failure, for the UI to show and then clear.
    @Published private(set) var lastFailure: ServerAccountFailure?

    private let api: any PulseCueAccountAPI
    private let tokenStore: any ServerSessionTokenStoring
    private let deviceName: String?

    /// Bumped by every authoritative operation; see `beginOperation`.
    private var operationGeneration: UInt64 = 0

    /// The outstanding provider sign-in permit, if any.
    ///
    /// Separate from `operationGeneration` on purpose. The generation says
    /// which operation owns the auth *state*; this says a provider flow is in
    /// progress — which begins earlier, when the user taps, and must hold
    /// across provider UI the app does not control.
    private var activePermit: ProviderSignInPermit?
    private var nextPermitID: UInt64 = 0

    init(
        api: any PulseCueAccountAPI,
        tokenStore: any ServerSessionTokenStoring,
        deviceName: String? = nil
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.deviceName = deviceName
        self.state = api.isConfigured ? .guest : .notConfigured
    }

    // MARK: - Operation ownership

    /// Claims ownership of the auth state and returns this operation's ticket.
    ///
    /// Starting any authoritative operation invalidates every one already in
    /// flight. That is the intent: tapping "sign out" while a restore is still
    /// waiting on `/me` means the restore's answer is no longer wanted,
    /// however good it turns out to be.
    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    /// Whether this operation is still the newest one.
    ///
    /// Checked after **every** `await`, immediately before writing state or
    /// touching the Keychain — never once at the top and assumed thereafter.
    private func isCurrent(_ generation: UInt64) -> Bool {
        generation == operationGeneration
    }

    // MARK: - Provider sign-in reservation

    /// Decides whether a provider sign-in may start, **before** the provider
    /// SDK is touched.
    ///
    /// This is the authoritative gate. The UI may also disable a button, but
    /// nothing may reach `ASAuthorizationController` or `GIDSignIn` without a
    /// permit from here — otherwise the provider's own account state can
    /// change while PulseCue still holds a session for somebody else. For
    /// Google that is not hypothetical: the SDK switches its locally selected
    /// account as soon as the sheet completes, so a sign-in we would later
    /// refuse still leaves the device pointing at a different Google account.
    ///
    /// Two things it deliberately does **not** do:
    ///
    ///   It does not consult `state`. Only the Keychain knows whether this
    ///   device holds a session; `state` can disagree after a failed write, an
    ///   interrupted launch, or an unresolved `localCleanupFailed`.
    ///
    ///   It does not bump the operation generation on refusal. A refused
    ///   sign-in changed nothing, so invalidating an in-flight restore would
    ///   strand it — leaving `.restoring` on screen for a tap that was turned
    ///   away.
    func prepareProviderSignIn(
        provider: AuthProviderKind
    ) -> ProviderSignInPreparation {
        guard api.isConfigured else {
            fail(.notConfigured)
            return .notConfigured
        }

        // One provider flow at a time. Without this, tapping Apple and Google
        // together passes both preflights — each sees an empty Keychain — and
        // opens two authorization sheets.
        if activePermit != nil {
            return .busy
        }

        switch tokenStore.read() {
        case .token:
            // Overwriting it would strand the existing server session, and the
            // provider SDK would have changed its own account for nothing.
            fail(.existingSessionHeld)
            return .existingSession

        case .unavailable:
            // Unreadable is not empty. Proceeding risks overwriting a session
            // we simply could not see.
            if !state.holdsSession {
                state = .unreachable
            }
            fail(.credentialUnavailable)
            return .credentialUnavailable

        case .absent:
            nextPermitID &+= 1
            let permit = ProviderSignInPermit(id: nextPermitID, provider: provider)
            activePermit = permit
            return .allowed(permit)
        }
    }

    /// Ends a provider flow, however it ended.
    ///
    /// Must be called for success, failure, cancellation and SDK error alike —
    /// a leaked permit would leave the app permanently `busy` and unable to
    /// sign in at all.
    func finishProviderSignIn(_ permit: ProviderSignInPermit) {
        guard activePermit == permit else { return }
        activePermit = nil
    }

    /// Whether this permit is the outstanding one.
    private func isHolding(_ permit: ProviderSignInPermit) -> Bool {
        activePermit == permit
    }

    // MARK: - Launch restore

    /// Re-establishes the account at launch.
    ///
    ///   no token           → guest
    ///   token, 200         → authenticated
    ///   token, 401         → drop the token, guest
    ///   token, no network  → keep the token, unreachable
    ///
    /// The third and fourth lines are the ones that matter. They look similar
    /// from the call site and mean opposite things.
    func restore() async {
        let generation = beginOperation()

        guard api.isConfigured else {
            state = .notConfigured
            return
        }

        let token: String
        switch tokenStore.read() {
        case .unavailable:
            // The Keychain could not answer — most plausibly a background
            // launch before the first unlock. That says nothing about whether
            // a session exists, so nothing is deleted and the user is not
            // downgraded to Guest. Local features are unaffected.
            state = .unreachable
            return
        case .absent:
            state = .guest
            return
        case let .token(value):
            token = value
        }

        state = .restoring
        do {
            let profile = try await api.fetchProfile(sessionToken: token)
            // A logout or a new sign-in may have happened while `/me` was in
            // flight. Its answer must not resurrect a session the user
            // deliberately ended.
            guard isCurrent(generation) else { return }

            guard profile.isActive else {
                // The account is being deleted. Nothing to come back to.
                clearSession(generation: generation)
                return
            }
            state = .authenticated(profile)
        } catch let error as AccountAPIError where error.invalidatesStoredSession {
            guard isCurrent(generation) else { return }
            // The server genuinely refused it: revoked, expired, or the account
            // is gone. This is the only restore path that clears the Keychain —
            // and if that clear fails, the state says so rather than showing
            // Guest over a token still on disk.
            clearSession(generation: generation)
        } catch {
            guard isCurrent(generation) else { return }
            // Offline, timed out, 5xx, or a response we could not read. The
            // session is probably fine and the app is fully usable; only
            // account features wait.
            state = .unreachable
        }
    }

    // MARK: - Sign-in

    /// Trades a verified Apple credential for a PulseCue session.
    ///
    /// `authorizationCode` is required. Without it the server cannot obtain
    /// the refresh token it needs to revoke at account deletion, so a sign-in
    /// missing it must fail rather than create an account that can never be
    /// deleted properly. Apple provides it on every authorization; its absence
    /// means something went wrong, not that it is optional.
    ///
    /// Returns whether the app is now authenticated, so the caller knows
    /// whether it may record anything of its own.
    @discardableResult
    func signInWithApple(
        permit: ProviderSignInPermit,
        identityToken: String,
        authorizationCode: String,
        rawNonce: String
    ) async -> Bool {
        guard isHolding(permit) else { return false }
        guard api.isConfigured else {
            fail(.notConfigured)
            return false
        }
        guard !identityToken.isEmpty, !authorizationCode.isEmpty, !rawNonce.isEmpty else {
            fail(.missingProviderCredential)
            return false
        }

        let device = deviceName
        return await completeSignIn(permit: permit) { api in
            try await api.signInWithApple(
                AppleSignInRequest(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    rawNonce: rawNonce,
                    deviceName: device
                )
            )
        }
    }

    /// Trades a Google ID token for a PulseCue session.
    ///
    /// The ID token is the only thing sent. The SDK's `userID`, email and
    /// profile name are not identity as far as the server is concerned, and
    /// there is nowhere on the request to put them.
    @discardableResult
    func signInWithGoogle(
        permit: ProviderSignInPermit,
        idToken: String
    ) async -> Bool {
        guard isHolding(permit) else { return false }
        guard api.isConfigured else {
            fail(.notConfigured)
            return false
        }
        guard !idToken.isEmpty else {
            fail(.missingProviderCredential)
            return false
        }

        let device = deviceName
        return await completeSignIn(permit: permit) { api in
            try await api.signInWithGoogle(
                GoogleSignInRequest(idToken: idToken, deviceName: device)
            )
        }
    }

    /// The shared tail of both sign-ins.
    ///
    /// The ordering is the security-relevant part: the token is confirmed with
    /// the server *before* it is persisted, and every failure after the server
    /// issued it hands the token back rather than dropping it.
    private func completeSignIn(
        permit: ProviderSignInPermit,
        _ exchange: (any PulseCueAccountAPI) async throws -> ServerSessionResponse
    ) async -> Bool {
        // The second gate, and not redundant with `prepareProviderSignIn`.
        //
        // That one ran before the provider UI opened; the user then spent
        // however long they liked inside Apple's or Google's sheet, and
        // anything could have happened here meanwhile — a restore completing,
        // a session arriving. Re-reading now closes that window, so a token
        // that appeared while the sheet was up is never overwritten.
        guard isHolding(permit) else { return false }
        switch tokenStore.read() {
        case .token:
            fail(.existingSessionHeld)
            return false
        case .unavailable:
            if !state.holdsSession { state = .unreachable }
            fail(.credentialUnavailable)
            return false
        case .absent:
            break
        }

        // Only now does this become the authoritative operation. Bumping the
        // generation earlier would let a *refused* sign-in strand an in-flight
        // restore.
        let generation = beginOperation()
        state = .signingIn

        let response: ServerSessionResponse
        do {
            response = try await exchange(api)
        } catch let error as AccountAPIError {
            guard isCurrent(generation) else { return false }
            // No token was issued, so there is nothing to hand back.
            state = tokenStore.tokenIfPresent() == nil ? .guest : .unreachable
            fail(failure(for: error))
            return false
        } catch {
            guard isCurrent(generation) else { return false }
            state = .guest
            fail(.unreachable)
            return false
        }

        // ── A live server session exists from here. ───────────────────────
        // Every path below either persists it or hands it back.
        let token = response.sessionToken

        guard isCurrent(generation) else {
            // A logout, a deletion or a newer sign-in started while this one
            // was waiting. Its session is unwanted — and unwanted is not
            // harmless: left alone it is a live 60-day session nobody can see.
            await abandon(token, reason: "superseded_sign_in")
            return false
        }

        // Confirm with the server before persisting. A token we cannot use is
        // not worth writing to the Keychain, and asking now means the UI
        // describes a confirmed account rather than a hopeful one.
        let profile: ServerAccountProfile
        do {
            profile = try await api.fetchProfile(sessionToken: token)
        } catch let error as AccountAPIError where error.invalidatesStoredSession {
            guard isCurrent(generation) else { return false }
            // Already dead server-side; there is nothing to hand back.
            state = .guest
            fail(.rejected)
            return false
        } catch {
            // Not the "offline restore" case. There, the token is already ours
            // and is kept. Here the sign-in never completed, so leaving the
            // session behind would strand one we never recorded.
            await abandon(token, reason: "sign_in_verification_failed")
            guard isCurrent(generation) else { return false }
            state = .guest
            fail(.unreachable)
            return false
        }

        guard isCurrent(generation) else {
            await abandon(token, reason: "superseded_sign_in")
            return false
        }

        // Persist only after the session is confirmed usable.
        guard isCurrent(generation) else {
            // Checked immediately before the write, not only after `/me`.
            await abandon(token, reason: "superseded_sign_in")
            return false
        }
        guard tokenStore.store(token) == .stored else {
            // A session we cannot persist would evaporate at the next launch
            // and look like a random sign-out — while staying alive on the
            // server the whole time.
            await abandon(token, reason: "keychain_store_failed")
            guard isCurrent(generation) else { return false }
            fail(.couldNotStoreSession)
            // **Do not assume the device now holds nothing.** A failed write
            // says nothing about what was already there — an older token may
            // still be on disk, or the Keychain may be unreadable. Guess wrong
            // and the UI shows Guest over a live credential. Ask instead.
            reconcileStateWithKeychain()
            return false
        }

        guard isCurrent(generation) else {
            // Unreachable today: nothing suspends between the write above and
            // this check, so on the main actor no other operation can
            // interleave. Kept as a plain refusal.
            //
            // It deliberately deletes nothing. A cleanup that removed "the
            // stored token" could remove a *newer* sign-in's token — a worse
            // outcome than leaving a session the server expires on its own.
            await abandon(token, reason: "superseded_sign_in")
            return false
        }

        state = .authenticated(profile)
        lastFailure = nil
        return true
    }

    /// Best-effort return of a session this app has decided not to keep.
    ///
    /// Nothing is persisted, and nothing is logged but a fixed reason — the
    /// token is precisely the thing that must never reach a log. A failure
    /// here is not locally recoverable and does not change the outcome: the
    /// sign-in failed either way.
    private func abandon(_ token: String, reason: String) async {
        do {
            try await api.logout(sessionToken: token)
        } catch {
            // Deliberately absent: the token, the error body, any identifier.
            #if DEBUG
            print("[account] orphan_session_revocation_failed reason=\(reason)")
            #endif
        }
    }

    // MARK: - Logout

    /// Signs out of this device.
    ///
    /// The local part is what the user asked for, so it is attempted whatever
    /// the server says — nobody should be stuck signed in because the network
    /// is down, and the session expires on its own within 60 days regardless.
    ///
    /// But "signed out" requires the token to actually be gone. If the Keychain
    /// refuses to delete it, this says so rather than showing Guest over a
    /// token the next launch would read straight back.
    ///
    /// Local training data is untouched.
    @discardableResult
    func logout() async -> LogoutResult {
        let generation = beginOperation()
        let token = tokenStore.tokenIfPresent()

        if let token {
            do {
                try await api.logout(sessionToken: token)
            } catch {
                // Best effort. Whether the server heard us does not change
                // what has to happen locally.
            }
        }

        guard isCurrent(generation) else { return .signedOut }
        return clearSession(generation: generation)
    }

    // MARK: - Account deletion

    /// Asks the server to delete the PulseCue account.
    ///
    /// **This is not device data deletion.** Workouts, routines, history, gyms
    /// and health entries are local and stay exactly where they are. The UI
    /// must keep the two apart, because a user who confuses them loses
    /// everything.
    ///
    /// Nothing here infers a deletion it did not see. Only `200` means the
    /// account is gone; `202` means accepted and unfinished; anything else
    /// means the app does not know.
    func deleteAccount() async -> AccountDeletionResult {
        let generation = beginOperation()

        // Read the token explicitly rather than through `tokenIfPresent`: an
        // unreadable Keychain must not look like an absent one here. Without a
        // token no authenticated DELETE can be built, so **no request is
        // sent** — and a request never sent cannot have deleted anything.
        switch tokenStore.read() {
        case .unavailable:
            fail(.credentialUnavailable)
            return .notAttempted(.credentialUnavailable)

        case .absent:
            // No session. That is not evidence the server account is gone, so
            // it is not reported as deleted. The UI only offers deletion while
            // authenticated, so reaching this means local state is inconsistent
            // rather than that the work is already done.
            fail(.rejected)
            return .notAttempted(.notSignedIn)

        case let .token(token):
            do {
                let outcome = try await api.deleteAccount(sessionToken: token)
                guard isCurrent(generation) else {
                    return .notAttempted(.superseded)
                }
                // 200 and 202 both mean the server accepted it and has already
                // revoked every session, so the local token is dead either way
                // and clearing it is right.
                _ = clearSession(generation: generation)
                return outcome == .pending ? .pending : .deleted

            } catch let error as AccountAPIError where error.invalidatesStoredSession {
                guard isCurrent(generation) else {
                    return .notAttempted(.superseded)
                }
                // A 401/403 proves the *session* is unusable. It proves nothing
                // about the account — it is also exactly what a successful first
                // attempt looks like when its response is lost and the client
                // retries with an already-revoked token. The token is cleared
                // because it is certainly dead; the result stays honest about
                // what was never confirmed.
                _ = clearSession(generation: generation)
                fail(.rejected)
                return .notConfirmed(.authenticationRequired)

            } catch {
                guard isCurrent(generation) else {
                    return .notAttempted(.superseded)
                }
                // 5xx, timeout, offline. The server may have accepted it and
                // lost the response, or never seen it. The session is kept — it
                // may still be valid — and nothing is claimed.
                fail(.unreachable)
                return .notConfirmed(.unreachable)
            }
        }
    }

    // MARK: - Internals

    /// Removes the session from this device and reports whether it worked.
    ///
    /// Never touches local training data. Only moves to `.guest` when the token
    /// is definitely gone: a failed delete leaves it on disk, where the next
    /// launch would find it.
    @discardableResult
    private func clearSession(generation: UInt64) -> LogoutResult {
        switch tokenStore.delete() {
        case .removed, .absent:
            guard isCurrent(generation) else { return .signedOut }
            state = api.isConfigured ? .guest : .notConfigured
            return .signedOut
        case .failed:
            guard isCurrent(generation) else { return .localCleanupFailed }
            state = .localCleanupFailed
            fail(.couldNotClearSession)
            return .localCleanupFailed
        }
    }

    /// Sets the state from what the Keychain actually holds.
    ///
    /// Used after a write fails, where the interesting question is not "did my
    /// write succeed" — it plainly did not — but "what does this device hold
    /// now". Only a confirmed-empty Keychain permits Guest.
    private func reconcileStateWithKeychain() {
        switch tokenStore.read() {
        case .absent:
            // Confirmed empty: Guest is a claim the device can support.
            state = api.isConfigured ? .guest : .notConfigured
        case .token:
            // A session credential is on this device. Whatever else is true,
            // the app is not signed out.
            state = .localCleanupFailed
        case .unavailable:
            // Cannot prove it is empty, so cannot claim to be signed out.
            state = .unreachable
        }
    }

    private func fail(_ failure: ServerAccountFailure) {
        lastFailure = failure
    }

    func clearFailure() {
        lastFailure = nil
    }

    private func failure(for error: AccountAPIError) -> ServerAccountFailure {
        switch error {
        case .invalidCredentials: return .rejected
        case .notConfigured: return .notConfigured
        case .unavailable, .malformedResponse: return .unreachable
        }
    }
}
