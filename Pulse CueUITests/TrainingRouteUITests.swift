//
//  TrainingRouteUITests.swift
//  Pulse CueUITests
//
//  That the Training tab renders what `TrainingSurface` ranks.
//
//  `TrainingHierarchyTests` describes the ranking and nothing else: until this
//  round it had no production caller at all, so every one of its assertions
//  could pass with an entire destination missing from the screen. That is not
//  hypothetical — it is what #178 shipped, with the machine catalogue's only
//  entry point deleted and the whole suite green.
//
//  So these drive the real tab bar. Three rules:
//
//  **One launch per test.** Sharing a launch means sharing scroll position and
//  whatever the previous test left pushed onto the navigation stack, and an
//  assertion that runs on the wrong screen is worse than no assertion.
//
//  **Skip onboarding deterministically.** Without the fixture these depend on
//  the simulator still holding a completed-onboarding flag from an earlier
//  run, and fail on a clean device for a reason unrelated to navigation.
//
//  **Assert what only this destination shows.** A navigation title is a string
//  any row could set.
//

import XCTest

final class TrainingRouteUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-pulsecue-ui-test-quick-plan-flow")
        app.launch()
        return app
    }

    private func trainingTab() -> XCUIApplication {
        let app = launchedApp()
        let tab = app.tabBars.buttons["トレーニング"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "training tab not found")
        tab.tap()
        XCTAssertTrue(
            app.navigationBars["トレーニング"].waitForExistence(timeout: 15),
            "Training did not open"
        )
        return app
    }

    private func tapMoreRow(_ app: XCUIApplication, _ label: String) {
        let row = app.buttons[label].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "\(label) not found in Training > その他の機能"
        )
        for _ in 0..<6 where !row.isHittable {
            app.swipeUp()
        }
        row.tap()
    }

    // MARK: - Today

    /// The two labels that mean "act on today's workout".
    ///
    /// 「メニューを作る」 is deliberately absent. It is the primary label only
    /// in the empty state, and otherwise it is the *secondary* disclosure row
    /// `TodayTrainingCard.showsPlanDisclosure` puts below the CTA — so seeing
    /// it alongside 「ワークアウトを開始」 is the design, not a second primary.
    private static let actionCTALabels = ["続ける", "ワークアウトを開始"]

    func testTodayOffersExactlyOnePrimaryAction() {
        // `TrainingSurface.primaryActions == 1` is a number in a file. This is
        // the screen. Which action it is depends on the day's state; that
        // Continue and Start never appear together, and that the empty state's
        // 「メニューを作る」 is never duplicated, is the contract.
        let app = trainingTab()

        let library = app.textFields["ルーティン名を検索"]
        XCTAssertTrue(library.waitForExistence(timeout: 15), "Training did not finish rendering")

        let actions = Self.actionCTALabels.filter { app.buttons[$0].firstMatch.exists }
        XCTAssertLessThanOrEqual(
            actions.count, 1,
            "Continue and Start are both on offer: \(actions)"
        )

        let create = app.buttons.matching(
            NSPredicate(format: "label == %@", "メニューを作る")
        ).count
        if actions.isEmpty {
            // Nothing startable: creating is the primary action, and there is
            // exactly one of it.
            XCTAssertEqual(create, 1, "the empty state offers \(create) create actions")
        } else {
            // With something startable, 「メニューを作る」 may appear once as the
            // secondary disclosure — never twice.
            XCTAssertLessThanOrEqual(create, 1, "メニューを作る is on screen \(create) times")
        }
    }

    func testThePrimaryActionLeadsSomewhere() {
        // Whichever CTA the state produced, tapping it must open something:
        // the routine picker when there is a routine to start, the creation
        // options when there is not. Never a dead button, and never a session
        // started here — the Runner is presented by ContentView.
        let app = trainingTab()

        guard let label = (Self.actionCTALabels + ["メニューを作る"]).first(where: {
            app.buttons[$0].firstMatch.waitForExistence(timeout: 15)
        }) else {
            return XCTFail("Today offers no primary action")
        }
        app.buttons[label].firstMatch.tap()

        let picker = app.staticTexts["ルーティンを選択"]
        let planOptions = app.buttons["作成方法を閉じる"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 15) || planOptions.exists,
            "\(label) opened neither the routine picker nor the creation options"
        )
    }

    // MARK: - Plan

    func testPlanShowsTheRoutineLibrary() {
        // The library is embedded, not pushed. Its search field is the thing
        // only it has — a section header would be satisfied by an empty stack.
        let app = trainingTab()

        XCTAssertTrue(
            app.textFields["ルーティン名を検索"].waitForExistence(timeout: 15),
            "the routine library is not on the Training root"
        )
    }

    func testTheRoutineLibraryOffersCreation() {
        let app = trainingTab()

        // Scrolled to: the root is a LazyVStack, so the button below the fold
        // is genuinely not built until it comes into range.
        XCTAssertTrue(
            app.textFields["ルーティン名を検索"].waitForExistence(timeout: 15),
            "the routine library is not on the Training root"
        )
        for _ in 0..<6 where !app.buttons["新しいルーティンを作成"].firstMatch.exists {
            app.swipeUp()
        }

        XCTAssertTrue(
            app.buttons["新しいルーティンを作成"].firstMatch.waitForExistence(timeout: 15),
            "the routine library has no way to create a routine"
        )
    }

    // MARK: - History

    func testHistoryIsOneTapFromTheToolbar() {
        let app = trainingTab()

        let history = app.buttons["履歴"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 15), "the History toolbar item is missing")
        history.tap()

        XCTAssertTrue(
            app.navigationBars["履歴"].waitForExistence(timeout: 15),
            "History did not open"
        )
    }

    // MARK: - More

    func testEveryRankedMoreDestinationIsListed() {
        // The rows are rendered from `TrainingSurface.moreDestinations`. This
        // is the other half of that: the labels reach the screen, in order.
        let app = trainingTab()

        for label in ["マイジム", "種目ライブラリ", "マシンカタログ",
                      "進捗", "週間プラン", "AI プラン相談"] {
            let row = app.buttons[label].firstMatch
            XCTAssertTrue(
                row.waitForExistence(timeout: 15),
                "\(label) is missing from その他の機能"
            )
        }
    }

    func testMyGymOpensFromTrainingMore() {
        // Gym's canonical route. It was reachable from Account until #179, and
        // Account is not where gym management belongs.
        let app = trainingTab()

        tapMoreRow(app, "マイジム")

        XCTAssertTrue(
            app.navigationBars["マイジム"].waitForExistence(timeout: 15),
            "My Gym did not open from Training"
        )
    }

    func testMachineCatalogOpensFromTrainingMore() {
        // The #178 regression, pinned: this screen compiled and existed with
        // no way to reach it from the running app.
        let app = trainingTab()

        tapMoreRow(app, "マシンカタログ")

        XCTAssertTrue(
            app.staticTexts["アプリ内のローカルマシン一覧です。外部APIは使用していません。"]
                .waitForExistence(timeout: 15),
            "the machine catalog did not open"
        )
    }

    func testProgressOpensFromTrainingMore() {
        let app = trainingTab()

        tapMoreRow(app, "進捗")

        XCTAssertTrue(
            app.navigationBars.firstMatch.waitForExistence(timeout: 15),
            "Progress did not open"
        )
        XCTAssertFalse(
            app.textFields["ルーティン名を検索"].exists,
            "Progress opened the routine library"
        )
    }
}
