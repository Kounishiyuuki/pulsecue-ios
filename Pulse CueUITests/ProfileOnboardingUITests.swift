//
//  ProfileOnboardingUITests.swift
//  Pulse CueUITests
//
//  The post-sign-in profile onboarding screen, end to end, over the DEBUG
//  `-pulsecue-ui-test-profile-onboarding` fixture: the real screen for a fake
//  account, with its own on-disk store so a relaunch resumes it. When the
//  screen is shown (server-confirmed sign-in, adoption first) is unit-tested
//  in `ProfileOnboardingTests`; this is about the screen itself.
//

import XCTest

final class ProfileOnboardingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-profile-onboarding"]
        if reset { app.launchArguments += ["-pulsecue-ui-test-profile-onboarding-reset"] }
        app.launch()
        return app
    }

    private func next(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["profile-onboarding-next"]
    }

    private func assertStep(_ app: XCUIApplication, _ number: Int, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15), "not on \(title)", file: file, line: line)
        XCTAssertTrue(app.staticTexts["ステップ \(number) / 4"].exists, "progress not \(number)/4", file: file, line: line)
    }

    private func type(_ text: String, into identifier: String, _ app: XCUIApplication) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(identifier) not found")
        field.tap()
        field.typeText(text)
    }

    /// Picks `option` from a menu-style Form picker identified by `identifier`.
    private func pick(_ option: String, in identifier: String, _ app: XCUIApplication) {
        let picker = app.buttons[identifier].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "\(identifier) not found")
        picker.tap()
        let choice = app.buttons[option].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "option \(option) not offered")
        choice.tap()
    }

    private func completeBasics(_ app: XCUIApplication) {
        assertStep(app, 1, "基本情報")
        XCTAssertFalse(next(app).isEnabled, "basics advanced without a weight")
        type("72.5", into: "profile-onboarding-current-weight", app)
        XCTAssertTrue(next(app).isEnabled)
        next(app).tap()
    }

    private func completeGoal(_ app: XCUIApplication) {
        assertStep(app, 2, "目標")
        XCTAssertFalse(next(app).isEnabled, "goal advanced without a goal")
        pick("筋肥大", in: "profile-onboarding-goal", app)
        let goalWeight = app.textFields["profile-onboarding-goal-weight"]
        // An empty field reports its placeholder as its value.
        let current = goalWeight.value as? String ?? ""
        if current.isEmpty || current == goalWeight.placeholderValue {
            type("70", into: "profile-onboarding-goal-weight", app)
        }
        XCTAssertTrue(next(app).isEnabled)
        next(app).tap()
    }

    private func completeHabits(_ app: XCUIApplication) {
        assertStep(app, 3, "トレーニング習慣")
        XCTAssertFalse(next(app).isEnabled, "habits advanced without a level")
        pick("中級者", in: "profile-onboarding-experience", app)
        XCTAssertTrue(next(app).isEnabled)
        next(app).tap()
    }

    @MainActor
    func testFullFlowWithBackReachesHome() throws {
        let app = launch(reset: true)
        completeBasics(app)

        // Back returns to basics with the weight still entered.
        app.buttons["profile-onboarding-back"].tap()
        assertStep(app, 1, "基本情報")
        XCTAssertTrue(next(app).isEnabled, "basics lost its weight on back")
        next(app).tap()

        completeGoal(app)
        completeHabits(app)

        assertStep(app, 4, "準備完了")
        XCTAssertFalse(app.buttons["profile-onboarding-back"].exists, "back offered after saving")
        next(app).tap()
        XCTAssertTrue(app.staticTexts["profile-onboarding-fixture-home"].waitForExistence(timeout: 10), "did not finish")
    }

    @MainActor
    func testRelaunchResumesAtTheNextUnsavedStep() throws {
        var app = launch(reset: true)
        completeBasics(app)
        assertStep(app, 2, "目標")
        app.terminate()

        app = launch(reset: false)
        assertStep(app, 2, "目標")
        completeGoal(app)
        assertStep(app, 3, "トレーニング習慣")
        app.terminate()

        app = launch(reset: false)
        assertStep(app, 3, "トレーニング習慣")
        completeHabits(app)
        app.terminate()

        app = launch(reset: false)
        assertStep(app, 4, "準備完了")
        next(app).tap()
        XCTAssertTrue(app.staticTexts["profile-onboarding-fixture-home"].waitForExistence(timeout: 10))
        app.terminate()

        // Completed stays completed.
        app = launch(reset: false)
        XCTAssertTrue(app.staticTexts["profile-onboarding-fixture-home"].waitForExistence(timeout: 15))
    }
}
