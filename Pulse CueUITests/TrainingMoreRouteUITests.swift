//
//  TrainingMoreRouteUITests.swift
//  Pulse CueUITests
//
//  That the More section's destinations actually open.
//
//  Written because the failure it guards against was invisible to every other
//  kind of test: the machine catalogue's only entry point was a Settings card
//  that stopped being referenced, so the screen existed, compiled, and could
//  not be reached from the running app. Nothing failed. A contract test would
//  not have caught it either — it would have described a route the UI no
//  longer had.
//
//  So this drives the real tab bar and taps the real rows.
//

import XCTest

final class TrainingMoreRouteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches past onboarding deterministically.
    ///
    /// These two used a bare `launch()`, so they depended on the simulator
    /// still holding a completed-onboarding flag from an earlier run and
    /// failed on a clean device for a reason unrelated to navigation.
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-pulsecue-ui-test-quick-plan-flow")
        app.launch()
        return app
    }

    private func openTraining(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "training tab not found")
        tab.tap()
    }

    private func tapMoreRow(_ app: XCUIApplication, _ label: String) {
        let row = app.buttons[label].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "\(label) not found in Training > その他の機能"
        )
        if !row.isHittable { app.swipeUp() }
        row.tap()
    }

    func testMachineCatalogIsReachableFromTrainingMore() {
        let app = launchedApp()
        openTraining(app)

        tapMoreRow(app, "マシンカタログ")

        XCTAssertTrue(
            app.staticTexts["アプリ内のローカルマシン一覧です。外部APIは使用していません。"]
                .waitForExistence(timeout: 15),
            "machine catalog screen did not open"
        )
    }

    func testExerciseLibraryIsAReachableAndSeparateDestination() {
        // The two were one Settings card. Asserting both open proves they are
        // still two routes rather than one that happens to be listed twice.
        let app = launchedApp()
        openTraining(app)

        tapMoreRow(app, "種目ライブラリ")

        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 15),
            "exercise library did not open"
        )
        XCTAssertFalse(
            app.staticTexts["アプリ内のローカルマシン一覧です。外部APIは使用していません。"].exists,
            "exercise library opened the machine catalog"
        )
    }
}
