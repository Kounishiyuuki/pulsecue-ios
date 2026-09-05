//
//  UITestSupport.swift
//  Pulse CueUITests
//
//  The navigation boilerplate every route test repeats.
//
//  Four files had grown their own copy of "launch past onboarding, tap a tab,
//  wait for the screen" — and they had drifted: two skipped onboarding with a
//  fixture, two launched bare and so depended on the simulator still holding a
//  completed-onboarding flag from an earlier run.
//
//  Two rules these follow, because a bad helper is worse than a copy:
//
//  **Failures name the caller.** Every helper takes `file`/`line` and forwards
//  them, so a failure points at the test that asked rather than at this file.
//
//  **No sleeps.** Waiting is always on a condition with a timeout. A helper
//  that papered over a slow screen with a fixed delay would make every test
//  slower and still be flaky.
//

import XCTest

extension XCTestCase {

    /// A launched app, past onboarding, with a deterministic store.
    ///
    /// The quick-plan fixture is an existing DEBUG-only argument that skips
    /// onboarding and uses an in-memory store. What it seeds is irrelevant to
    /// most callers; its determinism is the point.
    func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("-pulsecue-ui-test-quick-plan-flow")
        app.launch()
        return app
    }

    /// Opens a bottom tab and waits for its screen.
    ///
    /// - Parameter screen: the navigation title to wait for. Defaults to the
    ///   tab's own label, which is the same string on every current tab.
    @discardableResult
    func openTab(
        _ tab: String,
        screen: String? = nil,
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "\(tab) tab not found",
            file: file, line: line
        )
        button.tap()

        let title = screen ?? tab
        XCTAssertTrue(
            app.navigationBars[title].waitForExistence(timeout: 15),
            "\(tab) did not open",
            file: file, line: line
        )
        return app
    }

    /// Scrolls until `element` is hittable, or gives up and says so.
    ///
    /// Lazy stacks do not build rows that are far off-screen, so `exists` is
    /// not enough to reach one. Bounded rather than looping forever: a missing
    /// row should fail the test, not hang it.
    func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 6,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(
            element.exists && element.isHittable,
            "\(name) never came into reach after \(maxSwipes) swipes",
            file: file, line: line
        )
    }

    /// Opens 「その他の機能」 from the Training root.
    ///
    /// The six occasional destinations used to be listed on the root itself,
    /// below the routine library — which put them further away the more
    /// routines the user had. They now sit behind one entry at a fixed
    /// position, so every test that wants one goes through here.
    @discardableResult
    func openTrainingMore(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let entry = app.buttons["その他の機能"].firstMatch
        XCTAssertTrue(
            entry.waitForExistence(timeout: 15),
            "the その他の機能 entry is missing from Training",
            file: file, line: line
        )
        scrollUntilHittable(entry, in: app, named: "その他の機能", file: file, line: line)
        entry.tap()

        XCTAssertTrue(
            app.navigationBars["その他の機能"].waitForExistence(timeout: 15),
            "その他の機能 did not open",
            file: file, line: line
        )
        return app
    }
}
