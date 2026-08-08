//
//  HomeProgressUITests.swift
//  Pulse CueUITests
//
//  Drives the real screens over the seeded-history fixture: Home surfaces a
//  トレーニング section, and the Progress screen shows this-week volume and
//  per-exercise progress.
//

import XCTest

final class HomeProgressUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-debug-glass-ui-route", route]
        app.launch()
        return app
    }

    @MainActor
    func testHomeShowsTrainingSection() throws {
        let app = launch(route: "home")
        // The workout-progress block appears once there is history.
        XCTAssertTrue(app.staticTexts["トレーニング"].waitForExistence(timeout: 12), "training section not shown on Home")
    }

    @MainActor
    func testProgressScreenShowsWeeklyAndExerciseProgress() throws {
        let app = launch(route: "progress")
        XCTAssertTrue(app.staticTexts["今週"].waitForExistence(timeout: 12), "weekly summary not shown")
        XCTAssertTrue(app.staticTexts["種目の進捗"].waitForExistence(timeout: 6), "exercise progress section not shown")
        // At least one exercise row with a personal-best chip.
        let pb = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "最多")).firstMatch
        XCTAssertTrue(pb.waitForExistence(timeout: 6), "no exercise progress row shown")
    }
}
