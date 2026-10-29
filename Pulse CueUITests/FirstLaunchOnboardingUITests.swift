//
//  FirstLaunchOnboardingUITests.swift
//  Pulse CueUITests
//
//  The first-launch screen offers Apple, Google and Guest side by side. Runs
//  over the DEBUG Visual QA route, which has no server account, so no
//  provider sheet or network call is involved. The guest path runs over the
//  `-pulsecue-ui-test-guest-first-launch` fixture: the real first-launch
//  cover, offline, with its own on-disk store so a relaunch resumes it.
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

    // MARK: - Guest profile onboarding

    private func launchGuestFixture(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-guest-first-launch"]
        if reset { app.launchArguments += ["-pulsecue-ui-test-guest-first-launch-reset"] }
        app.launch()
        return app
    }

    private func assertProfileStep(_ app: XCUIApplication, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15), "not on \(title)", file: file, line: line)
        XCTAssertFalse(app.staticTexts["guest-first-launch-fixture-home"].exists, "Home reached before completion", file: file, line: line)
    }

    private func weightWheel(_ identifier: String, whole: String, fraction: String, _ app: XCUIApplication) {
        let row = app.buttons[identifier].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(identifier) not found")
        row.tap()
        let wholePicker = app.pickerWheels.element(boundBy: 0)
        XCTAssertTrue(wholePicker.waitForExistence(timeout: 5), "\(identifier) whole wheel not shown")
        wholePicker.adjust(toPickerWheelValue: whole)
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: fraction)
        app.buttons["\(identifier)-done"].tap()
    }

    private func pick(_ option: String, in identifier: String, _ app: XCUIApplication) {
        let picker = app.buttons[identifier].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "\(identifier) not found")
        picker.tap()
        let choice = app.buttons[option].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "option \(option) not offered")
        choice.tap()
    }

    private func completeBasics(_ app: XCUIApplication) {
        assertProfileStep(app, "基本情報")
        XCTAssertEqual(app.buttons["profile-onboarding-age"].firstMatch.value as? String, "20 歳")
        XCTAssertFalse(app.buttons["profile-onboarding-next"].isEnabled, "basics advanced without a weight")
        weightWheel("profile-onboarding-current-weight", whole: "72", fraction: ".5", app)
        app.buttons["profile-onboarding-next"].tap()
    }

    private func completeRest(_ app: XCUIApplication) {
        assertProfileStep(app, "目標")
        pick("筋肥大", in: "profile-onboarding-goal", app)
        weightWheel("profile-onboarding-goal-weight", whole: "70", fraction: ".5", app)
        app.buttons["profile-onboarding-next"].tap()
        assertProfileStep(app, "トレーニング習慣")
        pick("中級者", in: "profile-onboarding-experience", app)
        app.buttons["profile-onboarding-next"].tap()
        assertProfileStep(app, "準備完了")
        app.buttons["profile-onboarding-next"].tap()
    }

    @MainActor
    func testGuestStartGoesThroughProfileOnboardingBeforeHome() throws {
        let app = launchGuestFixture(reset: true)

        // A fresh install in guest scope still starts with the three choices.
        XCTAssertTrue(app.buttons["onboarding.guest"].waitForExistence(timeout: 15), "guest start not shown")
        XCTAssertTrue(app.buttons["onboarding.apple"].exists, "Sign in with Apple not shown")
        XCTAssertFalse(app.navigationBars["基本情報"].exists, "profile shown before choosing")

        app.buttons["onboarding.guest"].tap()
        completeBasics(app)
        completeRest(app)
        XCTAssertTrue(app.staticTexts["guest-first-launch-fixture-home"].waitForExistence(timeout: 10), "did not reach Home")
        app.terminate()

        // Completed stays completed.
        let relaunched = launchGuestFixture(reset: false)
        XCTAssertTrue(relaunched.staticTexts["guest-first-launch-fixture-home"].waitForExistence(timeout: 15))
        XCTAssertFalse(relaunched.navigationBars["基本情報"].exists)
    }

    @MainActor
    func testGuestRelaunchResumesAtTheSavedStep() throws {
        var app = launchGuestFixture(reset: true)
        XCTAssertTrue(app.buttons["onboarding.guest"].waitForExistence(timeout: 15))
        app.buttons["onboarding.guest"].tap()
        completeBasics(app)
        assertProfileStep(app, "目標")
        app.terminate()

        app = launchGuestFixture(reset: false)
        assertProfileStep(app, "目標")
        XCTAssertFalse(app.buttons["onboarding.guest"].exists, "choices shown again after a saved step")
        completeRest(app)
        XCTAssertTrue(app.staticTexts["guest-first-launch-fixture-home"].waitForExistence(timeout: 10))
    }
}
