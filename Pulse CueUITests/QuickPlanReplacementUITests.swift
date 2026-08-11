//
//  QuickPlanReplacementUITests.swift
//  Pulse CueUITests
//
//  Exercise replacement through the real UI, reusing the quick-plan fixture
//  (an active gym with machines): swapping an exercise in the Preview, and
//  swapping the current exercise live in the Runner while the workout
//  continues.
//

import XCTest

final class QuickPlanReplacementUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-pulsecue-ui-test-quick-plan-flow")
        app.launch()
        return app
    }

    /// A previous test may leave a workout running; the app recovers it on the
    /// next launch and covers Today. End it so every test starts on Today.
    private func endRecoveredRunnerIfNeeded(_ app: XCUIApplication) {
        let end = app.buttons["セッションを中断して終了"]
        if end.waitForExistence(timeout: 3) {
            end.tap()
            let confirm = app.buttons["終了"]
            if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        }
    }

    /// Today → 今日のメニューを作る → 30分 → メニューを見る → Preview.
    ///
    /// The shortest bucket is chosen deliberately. Quick Plan now fills the
    /// requested time, so a 60-minute plan uses nearly every machine in the
    /// fixture gym — and Exercise Replacement, which only offers machines the
    /// workout is not already using, then correctly has nothing to suggest.
    /// A 30-minute plan leaves spares, which is what these tests exercise.
    private func openPreview(_ app: XCUIApplication) {
        endRecoveredRunnerIfNeeded(app)
        let entry = app.buttons["今日のメニューを作る"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Quick Plan entry missing")
        if !entry.isHittable { app.swipeUp() }
        entry.tap()

        let shortest = app.buttons["30分"].firstMatch
        XCTAssertTrue(shortest.waitForExistence(timeout: 8), "duration control missing")
        shortest.tap()

        let seeMenu = app.buttons["メニューを見る"]
        XCTAssertTrue(seeMenu.waitForExistence(timeout: 8), "condition CTA missing")
        seeMenu.tap()
    }

    /// The "種目を変更" affordance, found by its VoiceOver label suffix
    /// ("<name> を別の種目に変更"). firstMatch is the current exercise's button.
    private func changeExerciseButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "を別の種目に変更")).firstMatch
    }

    /// Taps via a coordinate — the replacement affordances sit inside a
    /// ScrollView with a sticky bottom bar, which XCUITest sometimes reports
    /// as "not hittable" even when fully visible.
    private func tap(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Taps the first candidate row in the open replacement sheet.
    private func pickFirstCandidate(_ app: XCUIApplication) {
        let sheetTitle = app.navigationBars["種目を変更"]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 8), "replacement sheet did not open")
        let candidate = app.buttons.matching(identifier: "replacement-candidate").firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 6), "no replacement candidate offered")
        candidate.tap()
        XCTAssertTrue(sheetTitle.waitForNonExistence(timeout: 6), "sheet did not dismiss after picking")
    }

    @MainActor
    func testReplaceExerciseInPreview() throws {
        let app = launch()
        openPreview(app)

        let start = app.buttons["この内容で開始"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "preview did not generate")

        let change = changeExerciseButton(app)
        XCTAssertTrue(change.waitForExistence(timeout: 6), "種目を変更 not found on preview")
        tap(change)

        pickFirstCandidate(app)

        // Back on the preview, intact and still startable.
        XCTAssertTrue(app.buttons["この内容で開始"].waitForExistence(timeout: 6), "preview not intact after replace")
    }

    @MainActor
    func testReplaceCurrentExerciseLiveInRunner() throws {
        let app = launch()
        openPreview(app)

        let start = app.buttons["この内容で開始"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "start button missing")
        start.tap()

        // Runner is up.
        let endSession = app.buttons["セッションを中断して終了"]
        XCTAssertTrue(endSession.waitForExistence(timeout: 12), "Runner did not start")

        // Swap the current (unstarted) exercise. firstMatch is the current
        // exercise's button (the next-exercise one appears later in the tree).
        let change = changeExerciseButton(app)
        XCTAssertTrue(change.waitForExistence(timeout: 6), "種目を変更 not found in Runner")
        tap(change)

        pickFirstCandidate(app)

        // The workout continues — the Runner is still present.
        XCTAssertTrue(endSession.waitForExistence(timeout: 8), "Runner did not continue after replacement")

        // Clean up so no recovered session leaks into the next test.
        endRecoveredRunnerIfNeeded(app)
    }
}
