//
//  TrainingUXPolishUITests.swift
//  Pulse CueUITests
//
//  The two Training problems this PR fixes, at the sizes that expose them.
//
//  Both are about a screen that behaves differently depending on how much the
//  user has in it, which is exactly what a fixed fixture cannot show. These
//  run against an exact routine count — 0, 1 and 20 — through a DEBUG-only
//  in-memory fixture, because the quick-plan argument reads the persistent
//  store and its library length is whatever the simulator was left holding.
//
//  **More reachability.** The six occasional destinations used to be listed
//  below the routine library, so the distance to My Gym grew with the number
//  of routines saved. The test that matters is the twenty-routine one: the
//  entry has to be reachable without scrolling past the library.
//
//  **Create CTA competition.** With no routines, Today and the empty library
//  both offered a filled Create. The contract is one primary action on the
//  root — the library keeps a way to create, one level quieter.
//

import XCTest

final class TrainingUXPolishUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Launch

    /// Training, with exactly `routines` user-saved routines.
    private func trainingTab(
        routines: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-training-routines", "\(routines)"]
        app.launch()
        return openTab("トレーニング", in: app, file: file, line: line)
    }

    /// The two labels that mean "act on today's workout".
    ///
    /// 「メニューを作る」 is deliberately absent: it is Today's primary only in
    /// the empty state, and otherwise it is the *secondary* disclosure row
    /// below the CTA, which is the design rather than a second primary.
    private static let todayActionLabels = ["続ける", "ワークアウトを開始"]

    // MARK: - Empty library: one primary action

    func testAnEmptyLibraryOffersExactlyOneCreateAction() {
        let app = trainingTab(routines: 0)

        // Today owns it.
        let todayCreate = app.buttons["メニューを作る"]
        XCTAssertTrue(todayCreate.firstMatch.waitForExistence(timeout: 15), "Today has no Create")

        // And offers it once. Three filled create buttons used to be on this
        // screen: Today's, the empty-state card's, and the library's floating
        // 新規作成 — the last two saying the same thing within one section.
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label == %@", "メニューを作る")).count, 1,
            "メニューを作る is on screen more than once"
        )
        XCTAssertFalse(
            app.buttons["新しいルーティンを作成"].exists,
            "the floating create button is still shown beside the empty-state card"
        )
    }

    func testAnEmptyLibraryStillLetsYouCreateFromThePlanSection() {
        // Demoted, not removed: someone who scrolled to the library must not
        // find a dead end there.
        let app = trainingTab(routines: 0)

        let planCreate = app.buttons["ルーティンを作成"].firstMatch
        scrollUntilHittable(planCreate, in: app, named: "ルーティンを作成")
        XCTAssertTrue(planCreate.exists, "the empty library offers no way to create")

        // A demoted button is not a smaller one.
        XCTAssertGreaterThanOrEqual(planCreate.frame.height, 44, "create target is under 44pt")
    }

    func testTodayIsTheOnlyPrimaryActionWhateverTheLibraryHolds() {
        // Empty: nothing to start, so Create is the action and there is no
        // Start or Continue beside it.
        let empty = trainingTab(routines: 0)
        XCTAssertTrue(
            empty.buttons["メニューを作る"].firstMatch.waitForExistence(timeout: 15),
            "the empty state offers no Create"
        )
        XCTAssertTrue(
            Self.todayActionLabels.filter { empty.buttons[$0].firstMatch.exists }.isEmpty,
            "the empty state offers Start or Continue with nothing to start"
        )

        // Populated: Start, and Create appears at most once as the secondary
        // disclosure — never as a second filled action.
        let populated = trainingTab(routines: 1)
        let actions = Self.todayActionLabels.filter { populated.buttons[$0].firstMatch.exists }
        XCTAssertEqual(actions, ["ワークアウトを開始"], "Today's action is \(actions)")
        XCTAssertLessThanOrEqual(
            populated.buttons.matching(
                NSPredicate(format: "label == %@", "メニューを作る")
            ).count,
            1,
            "メニューを作る is on screen more than once"
        )
    }

    // MARK: - Today's CTA follows the library, not a rule of its own

    func testASavedRoutineTurnsTodayIntoStart() {
        let app = trainingTab(routines: 1)

        XCTAssertTrue(
            app.buttons["ワークアウトを開始"].firstMatch.waitForExistence(timeout: 15),
            "Today does not offer Start with a saved routine"
        )
        XCTAssertFalse(
            app.buttons["続ける"].firstMatch.exists,
            "Continue is offered without an active workout"
        )
    }

    // MARK: - More reachability does not depend on the library

    func testMoreIsReachableWithTwentyRoutines() {
        // The regression this PR exists for. With the six destinations listed
        // below the library, reaching them here meant scrolling past twenty
        // routine cards.
        let app = trainingTab(routines: 20)

        let more = app.buttons["その他の機能"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "the More entry is missing")
        XCTAssertTrue(
            more.isHittable,
            "the More entry is not reachable without scrolling past the library"
        )
    }

    func testMoreDoesNotMoveAsTheLibraryGrows() {
        // The entry sits above the library, so its position is a function of
        // the Today card and nothing else. One routine and twenty put Today in
        // the same state, so the offset must be identical — not "similar".
        //
        // (The empty state is compared separately: Today's card is a different
        // height there, which moves everything below it by design.)
        var positions: [CGFloat] = []
        for count in [1, 20] {
            let app = trainingTab(routines: count)
            let more = app.buttons["その他の機能"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 15), "More missing with \(count) routines")
            XCTAssertTrue(more.isHittable, "More not hittable with \(count) routines")
            positions.append(more.frame.minY)
        }
        XCTAssertEqual(
            positions.first, positions.last,
            "the More entry moved with the library length"
        )
    }

    func testMoreIsReachableWithAnEmptyLibraryToo() {
        let app = trainingTab(routines: 0)
        let more = app.buttons["その他の機能"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "the More entry is missing")
        XCTAssertTrue(more.isHittable, "the More entry is not reachable")
    }

    func testMoreOpensTheDestinationList() {
        let app = trainingTab(routines: 20)

        let more = app.buttons["その他の機能"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "the More entry is missing")
        more.tap()

        XCTAssertTrue(
            app.navigationBars["その他の機能"].waitForExistence(timeout: 15),
            "その他の機能 did not open"
        )
        for label in ["マイジム", "種目ライブラリ", "マシンカタログ",
                      "進捗", "週間プラン", "AI プラン相談"] {
            XCTAssertTrue(
                app.buttons[label].firstMatch.waitForExistence(timeout: 10),
                "\(label) is missing from その他の機能"
            )
        }
    }

    // MARK: - The routes that were lost once before

    func testMyGymIsTwoTapsFromTrainingWithALongLibrary() {
        let app = trainingTab(routines: 20)

        app.buttons["その他の機能"].firstMatch.tap()
        let gym = app.buttons["マイジム"].firstMatch
        XCTAssertTrue(gym.waitForExistence(timeout: 15), "My Gym is missing")
        gym.tap()

        XCTAssertTrue(
            app.navigationBars["マイジム"].waitForExistence(timeout: 15),
            "My Gym did not open"
        )
    }

    func testMachineCatalogIsTwoTapsFromTrainingWithALongLibrary() {
        let app = trainingTab(routines: 20)

        app.buttons["その他の機能"].firstMatch.tap()
        let catalog = app.buttons["マシンカタログ"].firstMatch
        XCTAssertTrue(catalog.waitForExistence(timeout: 15), "the machine catalog is missing")
        catalog.tap()

        XCTAssertTrue(
            app.staticTexts["アプリ内のローカルマシン一覧です。外部APIは使用していません。"]
                .waitForExistence(timeout: 15),
            "the machine catalog did not open"
        )
    }

    func testHistoryIsStillOneTap() {
        // The More entry must not have cost History its place.
        let app = trainingTab(routines: 20)

        let history = app.buttons["履歴"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 15), "the History toolbar item is missing")
        history.tap()

        XCTAssertTrue(
            app.navigationBars["履歴"].waitForExistence(timeout: 15),
            "History did not open"
        )
    }

    // MARK: - The library itself is untouched

    func testTheRoutineLibraryStillSearchesAndCreates() {
        let app = trainingTab(routines: 20)

        XCTAssertTrue(
            app.textFields["ルーティン名を検索"].waitForExistence(timeout: 15),
            "the routine library is not on the Training root"
        )
        let create = app.buttons["新しいルーティンを作成"].firstMatch
        scrollUntilHittable(create, in: app, maxSwipes: 12, named: "新しいルーティンを作成")
        XCTAssertTrue(create.exists, "a populated library lost its create button")
    }

    // MARK: - Largest accessibility text

    func testTheMoreEntryAndPlanCreateSurviveTheLargestTextSize() {
        // AX XXXL is where a two-line row and a demoted button are most likely
        // to clip or lose their target. Both must stay reachable, and the
        // toolbar must still hold History beside the large title.
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-training-routines", "0"]
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ]
        app.launch()
        openTab("トレーニング", in: app)

        let more = app.buttons["その他の機能"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), "the More entry is missing at AX XXXL")
        XCTAssertGreaterThanOrEqual(more.frame.height, 44, "More target is under 44pt at AX XXXL")

        XCTAssertTrue(app.buttons["履歴"].firstMatch.exists, "History is missing at AX XXXL")

        let planCreate = app.buttons["ルーティンを作成"].firstMatch
        scrollUntilHittable(planCreate, in: app, maxSwipes: 10, named: "ルーティンを作成")
        XCTAssertGreaterThanOrEqual(
            planCreate.frame.height, 44,
            "the Plan create target is under 44pt at AX XXXL"
        )
    }
}
