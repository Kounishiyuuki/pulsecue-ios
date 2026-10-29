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

/// 今日の記録: 続きを入力 walks the missing fields one sheet at a time, while a
/// card still opens a single edit. Runs on the quick-plan fixture's in-memory
/// store, which starts the day with nothing recorded.
final class DailyRecordSequenceUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func save(sheet title: String, typing text: String? = nil, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "\(title) sheet did not open")
        if let text {
            let field = app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "\(title) has no text field")
            field.tap()
            field.typeText(text)
        }
        bar.buttons["保存"].tap()
    }

    @MainActor
    func testContinueRecordingAdvancesThroughMissingFieldsToFourOfFour() throws {
        let app = launchedApp()
        let cta = app.buttons["today.record.continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20), "続きを入力 not shown with 0 / 4")
        cta.tap()

        save(sheet: "摂取カロリー", typing: "1800", in: app)
        save(sheet: "運動消費カロリー", typing: "300", in: app)
        save(sheet: "睡眠時間", in: app)
        save(sheet: "体重（kg）", in: app)

        XCTAssertTrue(app.staticTexts["4 / 4 入力済み"].waitForExistence(timeout: 10), "count did not reach 4 / 4")
        XCTAssertFalse(app.navigationBars["体重（kg）"].exists, "flow did not end after the last field")
        XCTAssertFalse(cta.exists, "続きを入力 still shown when everything is recorded")
    }

    @MainActor
    func testCancelEndsContinuousEntry() throws {
        let app = launchedApp()
        let cta = app.buttons["today.record.continue"]
        XCTAssertTrue(cta.waitForExistence(timeout: 20))
        cta.tap()

        let bar = app.navigationBars["摂取カロリー"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.buttons["キャンセル"].tap()

        XCTAssertTrue(cta.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["運動消費カロリー"].waitForExistence(timeout: 2), "cancel advanced to the next field")
        XCTAssertTrue(app.staticTexts["0 / 4 入力済み"].exists)
    }

    @MainActor
    func testCardEntryIsASingleEdit() throws {
        let app = launchedApp()
        XCTAssertTrue(app.buttons["today.record.continue"].waitForExistence(timeout: 20))

        let card = app.buttons["消費 未入力"]
        scrollUntilHittable(card, in: app, named: "消費 card")
        card.tap()
        save(sheet: "運動消費カロリー", typing: "250", in: app)

        XCTAssertFalse(app.navigationBars["睡眠時間"].waitForExistence(timeout: 2), "card entry continued to another field")
        XCTAssertFalse(app.navigationBars["摂取カロリー"].exists, "card entry continued to another field")
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["1 / 4 入力済み"].waitForExistence(timeout: 10))
    }
}
