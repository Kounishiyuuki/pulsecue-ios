//
//  MeRouteUITests.swift
//  Pulse CueUITests
//
//  That every section of マイページ actually opens.
//
//  The failure this guards against has already happened once in this project:
//  a screen kept compiling after its only entry point stopped being
//  referenced, and nothing noticed. Splitting one settings screen into four
//  entrances is the same shape of risk, so these drive the real tab bar and
//  tap the real rows.
//

import XCTest

final class MeRouteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openMe(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["マイページ"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "Me tab not found")
        tab.tap()
    }

    private func openSection(_ app: XCUIApplication, _ label: String) {
        let row = app.buttons[label].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(label) not found on Me")
        if !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(
            app.navigationBars[label].waitForExistence(timeout: 15),
            "\(label) did not open"
        )
    }

    func testBodyAndGoalsOpens() {
        let app = XCUIApplication()
        app.launch()
        openMe(app)
        openSection(app, "体と目標")
    }

    func testHealthOpens() {
        let app = XCUIApplication()
        app.launch()
        openMe(app)
        openSection(app, "ヘルスケア")
    }

    func testAccountOpensAndKeepsDeletionReachable() {
        let app = XCUIApplication()
        app.launch()
        openMe(app)
        openSection(app, "アカウント")

        // Deletion is the action someone needs when they have decided to
        // leave. Reorganising must not be how it gets buried.
        XCTAssertTrue(
            app.staticTexts["アカウント"].firstMatch.waitForExistence(timeout: 10),
            "account section did not render"
        )
    }

    func testAppSettingsOpens() {
        let app = XCUIApplication()
        app.launch()
        openMe(app)
        openSection(app, "アプリ設定")
    }

    func testTrainingFeaturesAreNotListedUnderMe() {
        // They moved to Training in #178. A duplicate route here would undo
        // that quietly, and duplicates are what made the old screen sprawl.
        let app = XCUIApplication()
        app.launch()
        openMe(app)
        openSection(app, "アプリ設定")

        for label in ["マイジム", "種目ライブラリ", "マシンカタログ", "週間プラン", "AI プラン相談"] {
            XCTAssertFalse(
                app.buttons[label].exists,
                "\(label) is still reachable from Me"
            )
        }
    }
}
