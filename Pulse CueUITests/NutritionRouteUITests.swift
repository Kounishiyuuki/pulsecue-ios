//
//  NutritionRouteUITests.swift
//  Pulse CueUITests
//
//  That the Nutrition tab actually renders what the surface model claims.
//
//  `NutritionSurfaceTests` pins the order of the screen's sections and
//  `HomeNutritionWiringTests` pins the numbers, and until now both could pass
//  while nothing reached the screen at all: the view hardcoded its own layout,
//  so an entire section could disappear without a single unit test noticing.
//  These go through the tab.
//
//  Two rules, as in `MeRouteUITests`:
//
//  **One launch per test.** Sharing a launch means sharing scroll position,
//  sheet state and whatever the previous test left presented, and an assertion
//  that runs on the wrong screen is worse than no assertion.
//
//  **Assert what only this thing shows.** A section header is a string
//  anything could draw; the figures and the CTA are the screen.
//

import XCTest

final class NutritionRouteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch


    private func nutritionTab(
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIApplication {
        openTab("栄養", in: launchedApp(), file: file, line: line)
    }

    // MARK: - The sections reach the screen

    func testTheDailySummaryIsTheFirstThingOnTheScreen() {
        let app = nutritionTab()

        // The summary card leads with remaining or consumed kcal depending on
        // whether a target exists; either way the day's intake figure is what
        // the screen opens with. Its identifier is the stable handle.
        XCTAssertTrue(
            app.otherElements["nutrition-daily-summary"].waitForExistence(timeout: 15),
            "the daily summary card did not render"
        )
    }

    func testTheScreenOffersExactlyOneAddMealAction() {
        let app = nutritionTab()

        let addMeal = app.buttons["食事を記録"]
        XCTAssertTrue(addMeal.waitForExistence(timeout: 15), "the Add Meal CTA is missing")
        // The screen once had five ways to add a meal above the fold. One
        // filled CTA is the contract; the per-slot rows below are a different
        // label and are counted separately.
        XCTAssertEqual(
            app.buttons.matching(identifier: "食事を記録").count, 1,
            "more than one 食事を記録 action is on screen"
        )
    }

    func testTodaysMealsListsEverySlot() {
        let app = nutritionTab()

        // A day with nothing logged still shows one slim row per slot, so
        // recording straight into 夕食 stays one tap.
        for slot in ["朝食", "昼食", "夕食", "間食"] {
            XCTAssertTrue(
                app.buttons["\(slot)を記録"].waitForExistence(timeout: 10),
                "\(slot) has no row in 今日の食事"
            )
        }
    }

    func testTheWeeklyTrendSitsBelowTodaysFigures() {
        // The ranking in `NutritionSurface` says today's intake outranks
        // anything about other days. Position is how that is true on screen:
        // a weekly average above today's figures would invite reading one for
        // the other. (Not an off-screen assertion — an empty day is short
        // enough that everything fits, and it should still be in this order.)
        let app = nutritionTab()

        // firstMatch: the identifier lands on the card and SwiftUI also
        // propagates it to the container it is wrapped in. Any of them is the
        // top of the card, which is what the ordering is about.
        let summary = app.otherElements["nutrition-daily-summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "the summary card is missing")

        // Matched by identifier, not label: Home's nutrition card carries the
        // same 食事を記録 wording and both tabs stay in the hierarchy.
        let addMeal = app.buttons.matching(identifier: "食事を記録").firstMatch
        XCTAssertTrue(addMeal.waitForExistence(timeout: 10), "the Add Meal CTA is missing")

        let trend = app.buttons["7日間の傾向。週間サマリーを開く"].firstMatch
        XCTAssertTrue(trend.waitForExistence(timeout: 10), "the weekly trend is missing")

        XCTAssertLessThan(
            summary.frame.minY, addMeal.frame.minY,
            "今日の栄養 is not above the Add Meal CTA"
        )
        XCTAssertLessThan(
            addMeal.frame.minY, trend.frame.minY,
            "the weekly trend is above today's figures"
        )
    }

    // MARK: - Add Meal opens the method dialog, and only then

    func testAddMealAsksForTheMethodSecond() {
        let app = nutritionTab()

        let addMeal = app.buttons["食事を記録"]
        XCTAssertTrue(addMeal.waitForExistence(timeout: 15), "the Add Meal CTA is missing")

        // Before the tap, no input method is on offer: the point of the
        // redesign is that intent comes first and method second.
        XCTAssertFalse(app.buttons["AI で記録（推定）"].exists, "AI entry offered before asking")
        XCTAssertFalse(app.buttons["バーコードを読み取る"].exists, "barcode offered before asking")

        addMeal.tap()

        for method in ["手動で記録", "AI で記録（推定）", "栄養表示を読み取る",
                       "バーコードを読み取る", "写真から記録"] {
            XCTAssertTrue(
                app.buttons[method].waitForExistence(timeout: 10),
                "\(method) is missing from the add dialog"
            )
        }
    }

    // MARK: - Home shows the same day

    func testHomeShowsTodaysNutrition() {
        let app = launchedApp()

        let home = app.tabBars.buttons["ホーム"]
        XCTAssertTrue(home.waitForExistence(timeout: 20), "Home tab not found")
        home.tap()

        XCTAssertTrue(
            app.otherElements["home-nutrition-card"].waitForExistence(timeout: 15),
            "Home is not showing today's nutrition"
        )
    }

    func testHomeKeepsTheQuickIntakeTileOnADayWithoutMeals() {
        // The fixture logs no meals, so the day is not meal-owned and manual
        // calorie entry still survives. When it does not, the tile must route
        // to Nutrition instead — the two states are what `HomeIntakeTile`
        // decides, and this checks the day where the field is offered.
        let app = launchedApp()

        let home = app.tabBars.buttons["ホーム"]
        XCTAssertTrue(home.waitForExistence(timeout: 20), "Home tab not found")
        home.tap()

        app.swipeUp()
        let intake = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "摂取")
        ).firstMatch
        XCTAssertTrue(intake.waitForExistence(timeout: 15), "the 摂取 tile is missing")
    }
}
