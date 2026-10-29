//
//  FirstLaunchOnboardingUITests.swift
//  Pulse CueUITests
//
//  The first-launch screen offers Apple, Google and Guest side by side. Runs
//  over the DEBUG Visual QA route, which has no server account, so no
//  provider sheet or network call is involved.
//

import XCTest

final class FirstLaunchOnboardingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testFirstLaunchOffersAppleGoogleAndGuest() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-debug-glass-ui-route", "onboarding"]
        app.launch()

        XCTAssertTrue(app.buttons["onboarding.guest"].waitForExistence(timeout: 12), "guest start not shown")
        XCTAssertTrue(app.buttons["onboarding.apple"].exists, "Sign in with Apple not shown")
        // DEBUG always presents the Google control (disabled when unconfigured).
        XCTAssertTrue(app.buttons["onboarding.google"].exists, "Google control not shown in DEBUG")
        XCTAssertTrue(app.staticTexts["ログインは任意です"].exists, "optional-login note not shown")
    }
}
