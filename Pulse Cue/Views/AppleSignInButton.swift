//
//  AppleSignInButton.swift
//  Pulse Cue
//
//  Apple's own Sign in with Apple button, with PulseCue deciding what a tap
//  does.
//
//  Two requirements pull in opposite directions here.
//
//  Apple's Human Interface Guidelines want the real control: its exact logo,
//  corner radius, type, localized title, and the accessibility and Dynamic
//  Type behaviour that come with it. A hand-built `Button` with an
//  `apple.logo` SF Symbol approximates the look and loses the rest — it also
//  ships a hardcoded Japanese title where the system control would follow the
//  user's language.
//
//  But `SignInWithAppleButton` — SwiftUI's wrapper — begins the authorization
//  itself, the instant it is tapped. There is no room in it for the Keychain
//  preflight that decides whether a sign-in may start at all, which is the
//  protection the account layer is built around.
//
//  `ASAuthorizationAppleIDButton` is the way to have both: it is the official
//  control as a plain UIKit button, with no authorization behaviour attached.
//  Wrapped here, it renders exactly as Apple intends and its tap runs whatever
//  we hand it — which is `ProviderSignInCoordinator`, so the order stays:
//
//      tap  →  Keychain preflight  →  permit  →  ASAuthorizationController
//
//  Going back to the system control did not go back to skipping the preflight.
//

import AuthenticationServices
import SwiftUI
import UIKit

struct AppleSignInButton: UIViewRepresentable {

    /// Run on tap. Async, because the preflight reads the Keychain and the
    /// flow that follows is asynchronous throughout.
    let action: () async -> Void

    /// Matches the surrounding dark UI. `.white` on PulseCue's dark cards
    /// would sit brighter than every other control on the screen; `.black` is
    /// the variant Apple provides for exactly this case.
    var style: ASAuthorizationAppleIDButton.Style = .black

    /// `.signIn` renders the localized "Sign in with Apple" title. The title
    /// is Apple's to choose — it follows the user's language, which a
    /// hardcoded Japanese string could not.
    var type: ASAuthorizationAppleIDButton.ButtonType = .signIn

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(
            authorizationButtonType: type,
            authorizationButtonStyle: style
        )
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.didTap),
            for: .touchUpInside
        )
        // The control brings its own accessibility label and traits from the
        // system; nothing is overridden here, so it stays correct in every
        // language and with VoiceOver.
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        // The action is a fresh closure on each SwiftUI update; the target is
        // the persistent coordinator, so only the closure needs replacing.
        context.coordinator.action = action
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () async -> Void

        init(action: @escaping () async -> Void) {
            self.action = action
        }

        @objc func didTap() {
            Task { await action() }
        }
    }
}
