//
//  WorkoutCompletionUITests.swift
//  Pulse CueUITests
//
//  Drives the real app end to end over the DEBUG completion fixture (an
//  in-memory store holding one one-set, zero-rest routine): start a workout,
//  finish it, read the Workout Completion screen, close it, and confirm
//  History gained exactly one entry.
//
//  The fixture only supplies data and skips onboarding — the Runner's
//  semantics, session finalization, and completion flow are the production
//  ones.
//

import XCTest

final class WorkoutCompletionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launchCompletionFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-completion-flow"]
        app.launch()
        return app
    }

    /// Opens the ワークアウト tab and starts the fixture routine.
    private func startFixtureWorkout(_ app: XCUIApplication) {
        let workoutTab = app.tabBars.buttons["ワークアウト"]
        XCTAssertTrue(workoutTab.waitForExistence(timeout: 20), "workout tab not found")
        workoutTab.tap()

        let start = app.buttons["このまま開始"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "start button not found")
        start.tap()

        XCTAssertTrue(
            app.staticTexts["現在の回数"].waitForExistence(timeout: 15),
            "Runner did not open"
        )
    }

    private func assertCompletionScreen(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts["ワークアウト完了"].waitForExistence(timeout: 15),
            "completion screen not shown"
        )
        XCTAssertTrue(app.staticTexts["実施時間"].exists, "duration metric missing")
        XCTAssertTrue(app.staticTexts["完了した種目"].exists, "exercise count metric missing")
        XCTAssertTrue(app.staticTexts["完了したセット"].exists, "set count metric missing")
    }

    @MainActor
    func testCompletingFinalSetShowsCompletionThenRecordsOneWorkout() throws {
        let app = launchCompletionFixture()
        startFixtureWorkout(app)

        let complete = app.buttons["このセットを完了して休憩へ"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10), "Complete action not found")
        complete.tap()

        assertCompletionScreen(app)

        let done = app.buttons["workout-completion-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "completion CTA not found")
        done.tap()

        // The Runner cover closes, revealing the tab bar again.
        let historyTab = app.tabBars.buttons["履歴"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 15), "Runner cover did not dismiss")
        historyTab.tap()

        XCTAssertTrue(
            app.staticTexts["最近のトレーニング"].waitForExistence(timeout: 15),
            "History did not list any workout"
        )
        let rows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "完了フローテスト")
        )
        XCTAssertEqual(rows.count, 1, "expected exactly one History entry")
    }

    @MainActor
    func testSkippingFinalExerciseShowsCompletion() throws {
        let app = launchCompletionFixture()
        startFixtureWorkout(app)

        let skip = app.buttons["この種目をスキップして次の種目へ"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "Skip action not found")
        skip.tap()

        assertCompletionScreen(app)
    }
}
