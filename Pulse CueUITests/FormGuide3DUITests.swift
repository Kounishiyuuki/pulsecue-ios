//
//  FormGuide3DUITests.swift
//  Pulse CueUITests
//
//  Uses the DEBUG-only deterministic launch route
//  (`-pulsecue-ui-test-form-guide-3d`) to open the 3D Form Guide directly,
//  so the guide's structure can be asserted (and screenshots captured)
//  without the multi-step gym→plan navigation. Does not assert pixel-level
//  3D correctness — only that the surrounding UI is present and usable.
//

import XCTest

final class FormGuide3DUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testFormGuide3DRouteOpensAndHasControls() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-pulsecue-ui-test-form-guide-3d",
                                "-pulsecue-ui-test-exercise-id", "machine_chest_press"]
        app.launch()

        // Guide opened.
        XCTAssertTrue(app.navigationBars["フォームガイド"].waitForExistence(timeout: 8),
                      "Form Guide did not open via the deterministic route")

        // Attach a screenshot for manual review.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "form-guide-3d-chest-press"
        shot.lifetime = .keepAlways
        add(shot)

        // Playback + speed + camera controls exist.
        XCTAssertTrue(app.buttons["再生"].exists || app.buttons["一時停止"].exists,
                      "play/pause control missing")
        XCTAssertTrue(app.buttons["再生速度 0.5x"].exists, "0.5x control missing")
        XCTAssertTrue(app.buttons["再生速度 1.0x"].exists, "1.0x control missing")
        XCTAssertTrue(app.buttons["視点 正面"].exists || app.buttons["視点 側面"].exists,
                      "camera preset control missing")

        // Text guide remains present.
        XCTAssertTrue(app.staticTexts["基本の動き"].waitForExistence(timeout: 3),
                      "text guide section missing")

        // Dismiss works.
        app.buttons["閉じる"].firstMatch.tap()
    }
}
