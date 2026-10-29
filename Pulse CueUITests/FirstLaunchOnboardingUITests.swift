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

    @MainActor
    func testWaitingForGuestAdoptionOffersNoWayOut() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-debug-glass-ui-route", "first-launch-waiting"]
        app.launch()

        XCTAssertTrue(app.activityIndicators["first-launch.waiting"].waitForExistence(timeout: 12), "waiting state not shown")
        XCTAssertFalse(app.buttons["onboarding.guest"].exists, "guest start must not be reachable")
        XCTAssertFalse(app.buttons["onboarding.apple"].exists, "Apple must not restart")
        XCTAssertFalse(app.buttons["onboarding.google"].exists, "Google must not restart")
        XCTAssertEqual(app.buttons.count, 0, "no action of any kind while waiting")
    }
}
