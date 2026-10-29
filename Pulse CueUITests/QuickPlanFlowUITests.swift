//
//  QuickPlanFlowUITests.swift
//  Pulse CueUITests
//
//  Drives the Quick Plan vertical slice through the real UI:
//  Today → 今日のメニューを作る → conditions → Preview → この内容で開始 → Runner,
//  plus the save branch. The app launches with a DEBUG fixture that seeds an
//  active gym with a few machines so the Today card reaches its Quick Plan
//  state; everything after that is user-visible navigation.
//

import XCTest

final class QuickPlanFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launchQuickPlanApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-pulsecue-ui-test-quick-plan-flow")
        app.launch()
        return app
    }

    /// Opens the Quick Plan condition sheet from Today and pushes into the
    /// generated preview. Returns the app positioned on the preview.
    private func openQuickPlanPreview(_ app: XCUIApplication) {
        openHomePlanOptions(app)
        let entry = app.buttons["今日のメニューを作る"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Quick Plan entry not found on Today")
        if !entry.isHittable { app.swipeUp() }
        entry.tap()

        let seeMenu = app.buttons["メニューを見る"]
        XCTAssertTrue(seeMenu.waitForExistence(timeout: 8), "Quick Plan condition CTA not found")
        // Default conditions (胸 preselected, 60分, 標準) are enough to generate.
        seeMenu.tap()
    }

    @MainActor
    func testStartWorkoutFromQuickPlan() throws {
        let app = launchQuickPlanApp()
        openQuickPlanPreview(app)

        let start = app.buttons["この内容で開始"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Start button not found on preview")
        start.tap()

        // The shared Runner-start path presents the Runner cover from the app
        // root; its end-session control is a stable, phase-independent marker.
        let endSession = app.buttons["セッションを中断して終了"]
        XCTAssertTrue(endSession.waitForExistence(timeout: 12), "Runner did not start from Quick Plan")
    }

    @MainActor
    func testSaveFromQuickPlan() throws {
        let app = launchQuickPlanApp()
        openQuickPlanPreview(app)

        let save = app.buttons["保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save button not found on preview")
        save.tap()

        // On success the preview swaps its CTA for a 完了 button.
        let done = app.buttons["完了"]
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Save did not reach the saved state")
    }

    @MainActor
    func testConditionScreenOffersExtendedDurationAndExerciseCount() throws {
        let app = launchQuickPlanApp()
        openHomePlanOptions(app)
        let entry = app.buttons["今日のメニューを作る"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Quick Plan entry not found on Today")
        if !entry.isHittable { app.swipeUp() }
        entry.tap()

        let durationMenu = app.buttons["quickPlanDurationPicker"].firstMatch
        XCTAssertTrue(durationMenu.waitForExistence(timeout: 8), "duration menu missing")
        XCTAssertTrue(durationMenu.label.contains("60分"), "default duration is not 60分: \(durationMenu.label)")
        durationMenu.tap()
        let longest = app.buttons["180分"].firstMatch
        XCTAssertTrue(longest.waitForExistence(timeout: 5), "180分 option missing")
        longest.tap()

        let countMenu = app.buttons["quickPlanExerciseCountPicker"].firstMatch
        XCTAssertTrue(countMenu.waitForExistence(timeout: 5), "exercise count menu missing")
        XCTAssertTrue(countMenu.label.contains("おまかせ"), "default count is not おまかせ: \(countMenu.label)")
        countMenu.tap()
        let four = app.buttons["4種目"].firstMatch
        XCTAssertTrue(four.waitForExistence(timeout: 5), "4種目 option missing")
        four.tap()

        app.buttons["メニューを見る"].firstMatch.tap()
        let estimate = app.descendants(matching: .any)["quickPlanEstimatedMinutes"].firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 10), "estimate missing on preview")
    }

    @MainActor
    func testEditingSetsUpdatesTheEstimate() throws {
        let app = launchQuickPlanApp()
        openQuickPlanPreview(app)

        let estimate = app.descendants(matching: .any)["quickPlanEstimatedMinutes"].firstMatch
        XCTAssertTrue(estimate.waitForExistence(timeout: 10), "estimate missing on preview")
        let before = estimate.label

        let setsStepper = app.steppers.matching(NSPredicate(format: "label ENDSWITH %@", "セット数")).firstMatch
        XCTAssertTrue(setsStepper.waitForExistence(timeout: 5), "sets stepper missing")
        let increment = setsStepper.buttons.element(boundBy: 1)
        for _ in 0..<3 { increment.tap() }

        let changed = NSPredicate(format: "label != %@", before)
        expectation(for: changed, evaluatedWith: estimate)
        waitForExpectations(timeout: 5)
    }
}
