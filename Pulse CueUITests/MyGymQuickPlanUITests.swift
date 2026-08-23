//
//  MyGymQuickPlanUITests.swift
//  Pulse CueUITests
//
//  My Gym is where a user picks their machines, and it used to offer only the
//  single-body-part generator — so that user never met the 時間 / 強度
//  controls. These drive the real screens over the quick-plan fixture to
//  prove the Quick Plan route is reachable from My Gym, that it asks for
//  duration and intensity, and that the original body-part route is still
//  there.
//

import XCTest

final class MyGymQuickPlanUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func launchAndOpenMyGym() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-pulsecue-ui-test-quick-plan-flow")
        app.launch()

        // Home → メニューを作る → "ジムを変更" is the entry into My Gym.
        openHomePlanOptions(app)
        let changeGym = app.buttons["ジムを変更"].firstMatch
        XCTAssertTrue(changeGym.waitForExistence(timeout: 15), "My Gym entry not found on Today")
        if !changeGym.isHittable { app.swipeUp() }
        changeGym.tap()
        return app
    }

    @MainActor
    func testMyGymOffersBothQuickPlanAndBodyPartRoutes() throws {
        let app = launchAndOpenMyGym()

        let quickPlan = app.buttons["今日のメニューを作る"].firstMatch
        XCTAssertTrue(
            quickPlan.waitForExistence(timeout: 15),
            "Quick Plan entry missing from My Gym"
        )
        // The original single-body-part generator must remain available.
        XCTAssertTrue(
            app.buttons["部位を選んで作成"].firstMatch.waitForExistence(timeout: 6),
            "body-part route was removed from My Gym"
        )
    }

    @MainActor
    func testMyGymQuickPlanAsksForDurationAndIntensity() throws {
        let app = launchAndOpenMyGym()

        let quickPlan = app.buttons["今日のメニューを作る"].firstMatch
        XCTAssertTrue(quickPlan.waitForExistence(timeout: 15), "Quick Plan entry missing")
        if !quickPlan.isHittable { app.swipeUp() }
        quickPlan.tap()

        XCTAssertTrue(
            app.staticTexts["時間"].waitForExistence(timeout: 10),
            "duration control not shown"
        )
        XCTAssertTrue(app.staticTexts["強度"].exists, "intensity control not shown")
        XCTAssertTrue(
            app.buttons["メニューを見る"].firstMatch.exists,
            "generate CTA not shown"
        )
    }

    @MainActor
    func testMyGymQuickPlanReachesPreview() throws {
        let app = launchAndOpenMyGym()

        let quickPlan = app.buttons["今日のメニューを作る"].firstMatch
        XCTAssertTrue(quickPlan.waitForExistence(timeout: 15), "Quick Plan entry missing")
        if !quickPlan.isHittable { app.swipeUp() }
        quickPlan.tap()

        let seeMenu = app.buttons["メニューを見る"].firstMatch
        XCTAssertTrue(seeMenu.waitForExistence(timeout: 10), "generate CTA not found")
        seeMenu.tap()

        // The existing preview screen, generated from this gym's equipment.
        XCTAssertTrue(
            app.staticTexts["これから行うメニュー"].waitForExistence(timeout: 15),
            "Quick Plan preview not reached from My Gym"
        )
    }
}
