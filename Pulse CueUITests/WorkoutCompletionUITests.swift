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

    /// Opens the トレーニング tab and starts the fixture routine.
    private func startFixtureWorkout(_ app: XCUIApplication) {
        let trainingTab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 20), "training tab not found")
        trainingTab.tap()

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
        XCTAssertTrue(app.staticTexts["種目"].exists, "exercise count metric missing")
        XCTAssertTrue(app.staticTexts["セット"].exists, "set count metric missing")
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

        // The Runner cover closes, revealing the tab bar again. History is no
        // longer a tab: it is reached from Training, which is where the
        // completed workout came from.
        let trainingTab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 15), "Runner cover did not dismiss")
        trainingTab.tap()

        let historyEntry = app.buttons["履歴"].firstMatch
        XCTAssertTrue(historyEntry.waitForExistence(timeout: 15), "History entry not found in Training")
        historyEntry.tap()

        XCTAssertTrue(
            app.staticTexts["最近のトレーニング"].waitForExistence(timeout: 15),
            "History did not list any workout"
        )
        let rows = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "完了フローテスト")
        )
        XCTAssertEqual(rows.count, 1, "expected exactly one History entry")
    }

    /// A Free Workout left open shows in History as 進行中, and tapping it
    /// reopens that workout rather than the ordinary detail.
    @MainActor
    func testHistoryReopensAnInProgressFreeWorkout() throws {
        let app = launchCompletionFixture()
        let trainingTab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 20), "training tab not found")
        trainingTab.tap()

        // The card combines its title and subtitle into one label.
        let start = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "フリーワークアウトを開始")
        ).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "Free Workout start not found")
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        start.tap()

        let close = app.buttons["閉じる"]
        XCTAssertTrue(close.waitForExistence(timeout: 15), "Free Workout screen did not open")
        close.tap()

        let historyEntry = app.buttons["履歴"].firstMatch
        XCTAssertTrue(historyEntry.waitForExistence(timeout: 15), "History entry not found in Training")
        for _ in 0..<6 where !historyEntry.isHittable { app.swipeUp() }
        historyEntry.tap()

        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "フリーワークアウト", "進行中")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "in-progress Free Workout row not in History")
        row.tap()

        XCTAssertTrue(app.buttons["閉じる"].waitForExistence(timeout: 15), "History did not reopen the Free Workout")
        XCTAssertTrue(app.buttons["終了"].exists, "Free Workout finish action missing")
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

/// Set kinds in a real Free Workout, end to end: the kind menu, the "W" /
/// working numbering, changing a logged set, finishing, and History.
final class FreeWorkoutSetTypeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, labelBeginsWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Opens a Free Workout and adds `exercise`; its first row is selected.
    private func openWorkout(adding exercise: String, search: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-completion-flow"]
        app.launch()
        let trainingTab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 20), "training tab not found")
        trainingTab.tap()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "フリーワークアウトを開始")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "Free Workout start not found")
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        start.tap()
        let add = app.buttons["種目を追加"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "Free Workout screen did not open")
        add.tap()
        let field = app.textFields["種目を検索"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "exercise search not found")
        field.tap()
        field.typeText(search)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", exercise)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(exercise) not in picker")
        row.tap()
        return app
    }

    /// Kept for PR review of the rows as rendered.
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func chooseKind(_ app: XCUIApplication, _ name: String) {
        let menu = app.buttons["freeWorkout.setTypeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "set type menu not found")
        menu.tap()
        let option = app.buttons[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "\(name) option not found")
        option.tap()
    }

    @MainActor
    func testWarmupAndWorkingSetsAreNumberedLoggedAndShownInHistory() throws {
        let app = openWorkout(adding: "ベンチプレス", search: "ベンチ")

        chooseKind(app, "ウォームアップ")
        XCTAssertTrue(element(app, labelBeginsWith: "ウォームアップセット、").waitForExistence(timeout: 5), "row did not become a warm-up")
        XCTAssertEqual(app.buttons["freeWorkout.setTypeMenu"].value as? String, "ウォームアップ")
        app.buttons["ウォームアップセットを完了"].firstMatch.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "ウォームアップセット、").label.contains("完了"), "warm-up not logged")

        app.buttons["セットを追加"].firstMatch.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "セット 1、").waitForExistence(timeout: 5), "new row is not working set 1")
        snapshot("1-warmup-done-and-working-row")

        // Change the logged warm-up to working and back: numbers follow.
        element(app, labelBeginsWith: "ウォームアップセット、").tap()
        chooseKind(app, "通常セット")
        XCTAssertTrue(element(app, labelBeginsWith: "セット 2、").waitForExistence(timeout: 5), "numbers did not follow")
        XCTAssertFalse(element(app, labelBeginsWith: "ウォームアップセット、").exists)
        chooseKind(app, "ウォームアップ")
        XCTAssertTrue(element(app, labelBeginsWith: "ウォームアップセット、").waitForExistence(timeout: 5))

        element(app, labelBeginsWith: "セット 1、").tap()
        let complete = app.buttons["セット1を完了"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "working set complete not found")
        complete.tap()
        snapshot("2-mixed-rows-done")
        element(app, labelBeginsWith: "ウォームアップセット、").tap()
        let menu = app.buttons["freeWorkout.setTypeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["ウォームアップ"].waitForExistence(timeout: 5))
        snapshot("3-set-type-menu")
        app.buttons["ウォームアップ"].tap()                  // the current kind: no change

        app.buttons["終了"].tap()
        let save = app.buttons["終了して保存"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        let done = app.buttons["workout-completion-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "completion not shown")
        done.tap()

        let history = app.buttons["履歴"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 15), "History entry not found")
        for _ in 0..<6 where !history.isHittable { app.swipeUp() }
        history.tap()
        let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "フリーワークアウト")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "finished Free Workout not in History")
        entry.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "ウォームアップセット、完了").waitForExistence(timeout: 10), "History lost the warm-up")
        XCTAssertTrue(element(app, labelBeginsWith: "セット 1、完了").exists, "History working set 1 missing")
        XCTAssertTrue(app.staticTexts["W"].exists, "W label missing in History")
        snapshot("4-history")
    }

    @MainActor
    func testAnOpenRowKindSurvivesCloseAndResumeAndTimedRowsHaveNone() throws {
        let app = openWorkout(adding: "ベンチプレス", search: "ベンチ")
        chooseKind(app, "ウォームアップ")
        app.buttons["セットを追加"].firstMatch.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "セット 1、").waitForExistence(timeout: 5))
        // Removing the warm-up renumbers the row below.
        element(app, labelBeginsWith: "ウォームアップセット、").tap()
        app.buttons["ウォームアップセットを削除"].firstMatch.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "セット 1、").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, labelBeginsWith: "ウォームアップセット、").exists)
        chooseKind(app, "ウォームアップ")

        app.buttons["閉じる"].tap()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "再開")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 15), "resume not offered")
        for _ in 0..<6 where !resume.isHittable { app.swipeUp() }
        resume.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "ウォームアップセット、").waitForExistence(timeout: 10), "kind lost on resume")

        app.buttons["種目を追加"].tap()
        let field = app.textFields["種目を検索"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("トレッドミル")
        let tread = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "トレッドミルウォームアップ")).firstMatch
        XCTAssertTrue(tread.waitForExistence(timeout: 10))
        tread.tap()
        // The timed row is selected: its editor has no kind menu.
        XCTAssertTrue(app.staticTexts["トレッドミルウォームアップ"].waitForExistence(timeout: 10), "timed card not added")
        XCTAssertFalse(app.buttons["freeWorkout.setTypeMenu"].exists, "timed row offers a set type")
        snapshot("5-timed-row")
    }
}
