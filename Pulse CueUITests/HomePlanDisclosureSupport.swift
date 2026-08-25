import XCTest

/// Opens Home's 「メニューを作る」 disclosure.
///
/// Plan creation moved under the Training card in Phase 2 (Home
/// simplification): the primary action on Home is starting a workout, and
/// the plan-generation routes sit one tap behind it rather than beside it.
func openHomePlanOptions(_ app: XCUIApplication) {
    let disclosure = app.buttons["メニューを作る"].firstMatch
    XCTAssertTrue(
        disclosure.waitForExistence(timeout: 15),
        "Home plan disclosure not found"
    )
    if !disclosure.isHittable { app.swipeUp() }
    disclosure.tap()
}
