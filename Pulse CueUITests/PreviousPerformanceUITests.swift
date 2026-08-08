//
//  PreviousPerformanceUITests.swift
//  Pulse CueUITests
//
//  Drives the real RunnerView over a seeded-history fixture (the DEBUG
//  runner-active-previous-performance route) and asserts the Previous
//  Performance / suggestion card is shown, that applying the suggestion keeps
//  the workout running, and that the current set controls remain present.
//

import XCTest

final class PreviousPerformanceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launchRunnerWithHistory() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-debug-glass-ui-route", "runner-active-previous-performance"]
        app.launch()
        return app
    }

    @MainActor
    func testPreviousPerformanceCardIsShown() throws {
        let app = launchRunnerWithHistory()
        XCTAssertTrue(app.staticTexts["前回"].waitForExistence(timeout: 12), "Previous Performance label not shown")
        XCTAssertTrue(app.staticTexts["今回の目安"].waitForExistence(timeout: 6), "Suggestion label not shown")
        // Current-set controls remain the focus.
        XCTAssertTrue(app.staticTexts["現在の回数"].exists, "current reps control missing")
    }

    @MainActor
    func testApplyingSuggestionKeepsWorkoutRunning() throws {
        let app = launchRunnerWithHistory()
        let apply = app.buttons["目安のレップ数を適用"]
        XCTAssertTrue(apply.waitForExistence(timeout: 12), "apply-suggestion button not found")
        apply.tap()
        // The workout is unaffected: the Complete action and the current-set
        // control are still present.
        XCTAssertTrue(app.staticTexts["現在の回数"].waitForExistence(timeout: 6), "runner not still active after applying")
    }
}
