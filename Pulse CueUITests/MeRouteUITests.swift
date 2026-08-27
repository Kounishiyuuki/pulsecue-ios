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

    /// Launches past onboarding deterministically.
    ///
    /// These tests previously relied on the simulator still holding a
    /// completed-onboarding flag from an earlier run, so a fresh device would
    /// have failed them for a reason that has nothing to do with navigation.
    /// The quick-plan fixture is an existing DEBUG-only argument that skips
    /// onboarding and uses an in-memory store; what it seeds is irrelevant
    /// here, its determinism is the point.
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-pulsecue-ui-test-quick-plan-flow")
        app.launch()
        return app
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
        let app = launchedApp()
        openMe(app)
        openSection(app, "体と目標")
    }

    func testHealthOpens() {
        let app = launchedApp()
        openMe(app)
        openSection(app, "ヘルスケア")
    }

    func testAccountOpensAndKeepsDeletionReachable() {
        let app = launchedApp()
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
        let app = launchedApp()
        openMe(app)
        openSection(app, "アプリ設定")
    }

    func testAccountOffersNoRouteIntoProfileOrGym() {
        // 「プロフィールとジムの設定」 lived here and was not a profile screen:
        // it registered gyms and opened My Gym, so Account — authentication,
        // sync and deletion — was a way into gym management.
        let app = launchedApp()
        openMe(app)
        openSection(app, "アカウント")

        for label in ["プロフィールとジムの設定", "マイジム", "ジムを変更"] {
            XCTAssertFalse(
                app.buttons[label].exists,
                "\(label) is still reachable from Account"
            )
        }
    }

    func testNoSectionOfMeLeadsToGymManagement() {
        // Checked across every section rather than Settings alone: the last
        // duplicate route was found in Account, not where it was looked for.
        let app = launchedApp()

        for section in ["体と目標", "ヘルスケア", "アカウント", "アプリ設定"] {
            openMe(app)
            openSection(app, section)

            for label in ["プロフィールとジムの設定", "マイジム", "マシンカタログ"] {
                XCTAssertFalse(
                    app.buttons[label].exists,
                    "\(label) is reachable from Me > \(section)"
                )
            }
        }
    }

    func testGymRemainsReachableFromTraining() {
        // Removing the duplicate must not remove the real one.
        let app = launchedApp()

        let training = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(training.waitForExistence(timeout: 20), "training tab not found")
        training.tap()

        let gym = app.buttons["マイジム"].firstMatch
        XCTAssertTrue(
            gym.waitForExistence(timeout: 15),
            "My Gym is no longer reachable from Training"
        )
    }

    func testTrainingFeaturesAreNotListedUnderMe() {
        // They moved to Training in #178. A duplicate route here would undo
        // that quietly, and duplicates are what made the old screen sprawl.
        let app = launchedApp()
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
