//
//  MeRouteUITests.swift
//  Pulse CueUITests
//
//  That every section of マイページ actually opens, and shows its own content.
//
//  The failure this guards against has already happened in this project: a
//  screen kept compiling after its only entry point stopped being referenced,
//  and nothing noticed. Four entrances into one settings screen is the same
//  shape of risk.
//
//  Two rules these follow, both learned the hard way.
//
//  **One launch per test.** An earlier version walked all four sections in a
//  single launch, tapping the Me tab between them and assuming that returns to
//  the root. Whether it does is a SwiftUI implementation detail, not a promise
//  — and when it does not, the "no gym route here" assertions become vacuously
//  true on whatever screen happens to be showing. Each test now starts from
//  its own launch and shares navigation state with nothing.
//
//  **Assert something only that destination has.** A navigation title is a
//  string any row could set. Each route checks for content that belongs to it,
//  so opening the wrong section fails instead of passing.
//

import XCTest

final class MeRouteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch


    /// A freshly launched app, already inside the named section of マイページ.
    private func appShowing(_ section: String) -> XCUIApplication {
        let app = launchedApp()

        let tab = app.tabBars.buttons["マイページ"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "Me tab not found")
        tab.tap()

        let row = app.buttons[section].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(section) not found on Me")
        if !row.isHittable { app.swipeUp() }
        row.tap()

        XCTAssertTrue(
            app.navigationBars[section].waitForExistence(timeout: 15),
            "\(section) did not open"
        )
        return app
    }

    // MARK: - Each section opens and shows its own content

    func testBodyAndGoalsShowsDerivedBodyFigures() {
        let app = appShowing("体と目標")

        XCTAssertTrue(
            app.otherElements["bmr-summary"].waitForExistence(timeout: 10),
            "体と目標 opened without its BMR figure"
        )
    }

    func testHealthShowsTheHealthKitIntegration() {
        let app = appShowing("ヘルスケア")

        XCTAssertTrue(
            app.staticTexts["ヘルスデータ連携"].waitForExistence(timeout: 10),
            "ヘルスケア opened without the HealthKit row"
        )
    }

    func testAccountShowsTheServerAccountState() {
        let app = appShowing("アカウント")

        XCTAssertTrue(
            app.staticTexts["PulseCueアカウント"].waitForExistence(timeout: 10),
            "アカウント opened without the server account section"
        )
    }

    func testAppSettingsShowsTheAppInformation() {
        let app = appShowing("アプリ設定")

        XCTAssertTrue(
            app.staticTexts["バージョン"].waitForExistence(timeout: 10),
            "アプリ設定 opened without the app information card"
        )
    }

    // MARK: - Account deletion
    //
    //  The destructive control renders only for an authenticated account, and
    //  these run as a guest. So this asserts the guest contract — the account
    //  section is present and correctly offers nothing destructive — rather
    //  than claiming to have found a delete button it cannot reach. The name
    //  says what it checks.
    //
    //  Covering the authenticated case needs a signed-in fixture, which is a
    //  follow-up rather than something to fake here.

    func testAGuestAccountSectionOffersNoDestructiveAction() {
        let app = appShowing("アカウント")

        XCTAssertTrue(
            app.staticTexts["PulseCueアカウント"].waitForExistence(timeout: 10),
            "account section did not render"
        )
        XCTAssertFalse(
            app.buttons["アカウントを削除"].exists,
            "a guest was offered account deletion"
        )
    }

    // MARK: - Gym belongs to Training, checked from every section
    //
    //  One test per section, each from its own launch. The duplicate that
    //  survived an earlier pass was in Account — not where anyone was looking
    //  — so every section is checked, and none can mask another by leaving the
    //  navigation stack somewhere unexpected.

    private func assertNoGymRoute(in app: XCUIApplication, section: String) {
        for label in ["プロフィールとジムの設定", "マイジム", "マシンカタログ"] {
            XCTAssertFalse(
                app.buttons[label].exists,
                "\(label) is reachable from Me > \(section)"
            )
        }
    }

    func testBodyAndGoalsHasNoGymRoute() {
        assertNoGymRoute(in: appShowing("体と目標"), section: "体と目標")
    }

    func testHealthHasNoGymRoute() {
        assertNoGymRoute(in: appShowing("ヘルスケア"), section: "ヘルスケア")
    }

    func testAccountHasNoGymRoute() {
        // 「プロフィールとジムの設定」 lived here and was not a profile screen:
        // it registered gyms and opened My Gym, so Account — authentication,
        // sync and deletion — was a way into gym management.
        assertNoGymRoute(in: appShowing("アカウント"), section: "アカウント")
    }

    func testAppSettingsHasNoTrainingFeatures() {
        // They moved to Training in #178. A duplicate here would undo that
        // quietly, and duplicates are what made the old screen sprawl.
        let app = appShowing("アプリ設定")

        for label in ["マイジム", "種目ライブラリ", "マシンカタログ", "週間プラン", "AI プラン相談"] {
            XCTAssertFalse(
                app.buttons[label].exists,
                "\(label) is still reachable from Me"
            )
        }
    }

    func testGymRemainsReachableFromTraining() {
        // Removing the duplicates must not remove the real one.
        let app = launchedApp()

        let training = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(training.waitForExistence(timeout: 20), "training tab not found")
        training.tap()

        XCTAssertTrue(
            app.buttons["マイジム"].firstMatch.waitForExistence(timeout: 15),
            "My Gym is no longer reachable from Training"
        )
    }

    // MARK: - Derived figures follow the profile being edited

    func testBodyMetricsUpdateWhileEditingTheProfile() {
        // BMR, TDEE and the target were once cached alongside the weight and
        // refreshed only on appear or on a DayLog change, so editing height on
        // this very screen left them showing figures from before the edit.
        // Only a UI test can see that: the values are rendered, and the
        // staleness lives in the view's state.
        let app = appShowing("体と目標")

        let bmr = app.otherElements["bmr-summary"].firstMatch
        XCTAssertTrue(bmr.waitForExistence(timeout: 15), "BMR summary not found")
        let before = bmr.label

        // Addressed by identifier rather than `steppers.firstMatch`, which
        // silently becomes a different control the moment one is added above.
        let heightStepper = app.steppers["height-stepper"].firstMatch
        XCTAssertTrue(heightStepper.waitForExistence(timeout: 10), "height stepper not found")
        if !heightStepper.isHittable { app.swipeUp() }
        // Several increments, so the change is larger than any rounding.
        for _ in 0..<5 {
            heightStepper.buttons.element(boundBy: 1).tap()
        }

        let updated = NSPredicate(format: "label != %@", before)
        expectation(for: updated, evaluatedWith: bmr)
        waitForExpectations(timeout: 10) { error in
            XCTAssertNil(
                error,
                "BMR did not update after editing height (was \(before), still \(bmr.label))"
            )
        }
    }
}
