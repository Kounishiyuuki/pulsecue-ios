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

/// The Free Workout rest timer, end to end: a completed set starts it, the
/// bar's −15 / +15 / 終了 work, the record stays, and it survives close and
/// resume. No assertion depends on exact seconds.
final class FreeWorkoutRestTimerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, labelBeginsWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func openBenchWorkout() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-completion-flow"]
        app.launch()
        let trainingTab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 20))
        trainingTab.tap()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "フリーワークアウトを開始")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        for _ in 0..<6 where !start.isHittable { app.swipeUp() }
        start.tap()
        let add = app.buttons["種目を追加"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        let field = app.textFields["種目を検索"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("ベンチ")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ベンチプレス")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        return app
    }

    @MainActor
    func testACompletedSetStartsARestThatCanBeAdjustedAndEnded() throws {
        let app = openBenchWorkout()
        let rest = app.descendants(matching: .any)["freeWorkout.restTime"]
        XCTAssertFalse(rest.exists, "rest shown before any set")
        app.buttons["セット1を完了"].firstMatch.tap()
        XCTAssertTrue(rest.waitForExistence(timeout: 5), "rest bar not shown after completing a set")
        XCTAssertEqual(rest.label, "残り休憩時間")

        let plus = app.buttons["休憩を15秒延長"]
        let minus = app.buttons["休憩を15秒短縮"]
        XCTAssertTrue(plus.exists && minus.exists)
        plus.tap()
        minus.tap()
        XCTAssertTrue(rest.exists, "rest ended by ±15")
        // Kind change and the logged set coexist with the running rest.
        XCTAssertTrue(element(app, labelBeginsWith: "セット 1、").label.contains("完了"))

        app.buttons["休憩を終了"].tap()
        XCTAssertFalse(rest.waitForExistence(timeout: 2), "rest still shown after 休憩を終了")
        XCTAssertTrue(element(app, labelBeginsWith: "セット 1、").label.contains("完了"), "the logged set was lost")
    }

    @MainActor
    func testTheRestKeepsRunningAcrossCloseAndResume() throws {
        let app = openBenchWorkout()
        app.buttons["セット1を完了"].firstMatch.tap()
        let rest = app.descendants(matching: .any)["freeWorkout.restTime"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "再開")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 15))
        for _ in 0..<6 where !resume.isHittable { app.swipeUp() }
        resume.tap()
        XCTAssertTrue(rest.waitForExistence(timeout: 10), "rest lost on close and resume")
        app.buttons["休憩を終了"].tap()
        XCTAssertFalse(rest.waitForExistence(timeout: 2))
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testTheTimerExpandsAndTheRestMenuSetsOnlyTheNextRests() throws {
        let app = openBenchWorkout()
        app.buttons["セット1を完了"].firstMatch.tap()
        let rest = app.descendants(matching: .any)["freeWorkout.restTime"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        snapshot(app, "freeWorkout-compact")

        rest.tap()
        let collapse = app.buttons["タイマーを小さく表示"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "the timer did not expand")
        XCTAssertTrue(app.buttons["休憩を15秒延長"].exists && app.buttons["休憩を終了"].exists)
        XCTAssertTrue(element(app, labelBeginsWith: "この休憩").exists)
        snapshot(app, "freeWorkout-expanded")
        collapse.tap()
        XCTAssertFalse(collapse.waitForExistence(timeout: 2))

        let menu = app.descendants(matching: .any)["freeWorkout.restMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertEqual(menu.value as? String, "02:00")
        menu.tap()
        let oneMinute = app.buttons["01:00"].firstMatch
        XCTAssertTrue(oneMinute.waitForExistence(timeout: 5), "the rest presets are not offered")
        snapshot(app, "freeWorkout-restSetting")
        oneMinute.tap()
        XCTAssertTrue(NSPredicate(format: "value == %@", "01:00").evaluate(with: menu) || menu.value as? String == "01:00")
        XCTAssertTrue(rest.exists, "changing the setting ended the running rest")
        app.buttons["休憩を終了"].tap()
        XCTAssertFalse(rest.waitForExistence(timeout: 2))
    }

    @MainActor
    func testHomesRestPillReopensTheWorkout() throws {
        let app = openBenchWorkout()
        app.buttons["セット1を完了"].firstMatch.tap()
        let rest = app.descendants(matching: .any)["freeWorkout.restTime"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        app.buttons["閉じる"].tap()
        let home = app.tabBars.buttons["ホーム"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        let pill = app.descendants(matching: .any)["home.restPill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "Home shows no rest pill")
        XCTAssertTrue(pill.label.contains("ベンチプレス"))
        snapshot(app, "home-restPill")
        pill.tap()
        XCTAssertTrue(rest.waitForExistence(timeout: 10), "the pill did not reopen the workout with its rest")
        app.buttons["休憩を終了"].tap()
        XCTAssertFalse(rest.waitForExistence(timeout: 2))
        app.buttons["閉じる"].tap()
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertFalse(pill.waitForExistence(timeout: 2), "the pill outlived the rest")
    }

    /// Starts the one-routine fixture's Runner and completes a set, so it
    /// rests. `largeText` launches at an accessibility text size.
    private func runnerResting(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-training-routines", "1"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"] }
        app.launch()
        // Whatever happens below, the Runner session does not outlive the
        // test: it is ended the way a user ends it.
        addTeardownBlock { [weak self] in self?.endRunnerSession(app, asserting: false) }
        let trainingTab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 20))
        trainingTab.tap()
        // The library is lazy: below the fold at large text sizes it does
        // not exist until scrolled to.
        let start = app.buttons["このまま開始"].firstMatch
        _ = start.waitForExistence(timeout: 5)
        for _ in 0..<10 where !(start.exists && start.isHittable) { app.swipeUp() }
        XCTAssertTrue(start.exists, "このまま開始 not found")
        start.tap()
        let complete = app.buttons["このセットを完了して休憩へ"]
        XCTAssertTrue(complete.waitForExistence(timeout: 15), "the Runner did not open")
        for _ in 0..<4 where !complete.isHittable { app.swipeUp() }
        complete.tap()
        return app
    }

    /// セッション終了 → 終了: the session is saved as abandoned, the Runner
    /// closes and nothing is left to restore on the next launch.
    private func endRunnerSession(_ app: XCUIApplication, asserting: Bool = true) {
        guard app.state == .runningForeground else { return }
        let end = app.buttons["セッションを中断して終了"].firstMatch
        guard end.waitForExistence(timeout: asserting ? 5 : 1) else {
            if asserting { XCTFail("no セッション終了 on the Runner") }
            return
        }
        for _ in 0..<6 where !end.isHittable { app.swipeUp() }
        end.tap()
        let confirm = app.alerts.buttons["終了"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() } else if asserting { XCTFail("no end confirmation") }
        guard asserting else { return }
        XCTAssertFalse(app.descendants(matching: .any)["runner.restDial"].waitForExistence(timeout: 2), "the Runner is still resting")
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["ホーム"].isHittable, "the Runner still covers the tabs")
    }

    @MainActor
    func testTheRunnersRestShowsTheBigClock() throws {
        let app = runnerResting()
        let dial = app.descendants(matching: .any)["runner.restDial"]
        XCTAssertTrue(dial.waitForExistence(timeout: 5), "no rest clock")
        XCTAssertTrue(dial.label.hasPrefix("残り"))
        XCTAssertTrue(app.buttons["休憩を15秒延長"].exists && app.buttons["休憩を15秒短縮"].exists, "the Runner is not ±15")
        snapshot(app, "runner-rest")
        endRunnerSession(app)
        // Relaunched, nothing comes back.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["runner.restDial"].waitForExistence(timeout: 3), "the Runner was restored")
        XCTAssertTrue(app.tabBars.buttons["ホーム"].isHittable)
    }

    @MainActor
    func testTheRunnersClockKeepsItsControlsAtALargeTextSize() throws {
        let app = runnerResting(largeText: true)
        let dial = app.descendants(matching: .any)["runner.restDial"]
        XCTAssertTrue(dial.waitForExistence(timeout: 5))
        let plus = app.buttons["休憩を15秒延長"], minus = app.buttons["休憩を15秒短縮"]
        XCTAssertTrue(plus.exists && minus.exists)
        for _ in 0..<4 where !plus.isHittable { app.swipeUp() }
        XCTAssertTrue(plus.isHittable && minus.isHittable, "±15 out of reach at a large text size")
        snapshot(app, "runner-rest-largeText")
        endRunnerSession(app)
    }

    @MainActor
    func testFreeWorkoutsRestKeepsItsControlsAtALargeTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-completion-flow",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        let trainingTab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(trainingTab.waitForExistence(timeout: 20))
        trainingTab.tap()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "フリーワークアウトを開始")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        for _ in 0..<8 where !start.isHittable { app.swipeUp() }
        start.tap()
        let add = app.buttons["種目を追加"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        let field = app.textFields["種目を検索"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("ベンチ")
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "ベンチプレス")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let done = app.buttons["セット1を完了"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        for _ in 0..<4 where !done.isHittable { app.swipeUp() }
        done.tap()
        let rest = app.descendants(matching: .any)["freeWorkout.restTime"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        for label in ["休憩を15秒短縮", "休憩を15秒延長", "休憩を終了"] {
            XCTAssertTrue(app.buttons[label].isHittable, "\(label) out of reach at a large text size")
        }
        snapshot(app, "freeWorkout-compact-largeText")
        app.buttons["休憩を終了"].tap()
        XCTAssertFalse(rest.waitForExistence(timeout: 2))
    }
}
