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

    /// Opens the wheel sheet behind `identifier`, turns it to `value` (the
    /// row's full text, unit included) and confirms with 完了.
    private func wheel(_ identifier: String, to value: String, _ app: XCUIApplication) {
        let row = app.buttons[identifier].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(identifier) not found")
        row.tap()
        let picker = app.pickerWheels.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "\(identifier) wheel not shown")
        picker.adjust(toPickerWheelValue: value)
        XCTAssertEqual(picker.value as? String, value, "\(identifier) wheel did not reach \(value)")
        app.buttons["\(identifier)-done"].tap()
        XCTAssertFalse(picker.waitForExistence(timeout: 1) && picker.isHittable, "\(identifier) sheet stayed open")
    }

    private func rowValue(_ identifier: String, _ app: XCUIApplication) -> String? {
        app.buttons[identifier].firstMatch.value as? String
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
        wheel("profile-onboarding-current-weight", to: "72.5 kg", app)
        XCTAssertEqual(rowValue("profile-onboarding-current-weight", app), "72.5 kg")
        XCTAssertTrue(next(app).isEnabled)
        next(app).tap()
    }

    private func completeGoal(_ app: XCUIApplication) {
        assertStep(app, 2, "目標")
        XCTAssertFalse(next(app).isEnabled, "goal advanced without a goal")
        pick("筋肥大", in: "profile-onboarding-goal", app)
        wheel("profile-onboarding-goal-weight", to: "70.0 kg", app)
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
    func testNewProfileStartsAtTwentyAndWheelsKeepValuesAcrossRelaunch() throws {
        var app = launch(reset: true)
        assertStep(app, 1, "基本情報")
        XCTAssertEqual(rowValue("profile-onboarding-age", app), "20 歳")
        XCTAssertEqual(rowValue("profile-onboarding-current-weight", app), "未設定")
        wheel("profile-onboarding-age", to: "34 歳", app)
        wheel("profile-onboarding-height", to: "178 cm", app)

        // キャンセル leaves the value as it was.
        app.buttons["profile-onboarding-age"].firstMatch.tap()
        let picker = app.pickerWheels.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.adjust(toPickerWheelValue: "50 歳")
        app.buttons["キャンセル"].tap()
        XCTAssertEqual(rowValue("profile-onboarding-age", app), "34 歳")

        completeBasics(app)
        app.terminate()

        app = launch(reset: false)
        assertStep(app, 2, "目標")
        app.buttons["profile-onboarding-back"].tap()
        assertStep(app, 1, "基本情報")
        XCTAssertEqual(rowValue("profile-onboarding-age", app), "34 歳")
        XCTAssertEqual(rowValue("profile-onboarding-height", app), "178 cm")
        XCTAssertEqual(rowValue("profile-onboarding-current-weight", app), "72.5 kg")
        next(app).tap()

        completeGoal(app)
        assertStep(app, 3, "トレーニング習慣")
        wheel("profile-onboarding-minutes", to: "75 分", app)
        wheel("profile-onboarding-days", to: "4 回", app)
        XCTAssertEqual(rowValue("profile-onboarding-minutes", app), "75 分")
        XCTAssertEqual(rowValue("profile-onboarding-days", app), "4 回")
        completeHabits(app)
        assertStep(app, 4, "準備完了")
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
