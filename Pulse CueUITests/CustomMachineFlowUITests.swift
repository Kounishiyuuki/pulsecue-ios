//
//  CustomMachineFlowUITests.swift
//  Pulse CueUITests
//
//  Drives the custom-machine management journey through the real UI. The
//  app launches with a narrow UI-test fixture that creates an active gym;
//  the rest of the flow uses user-visible navigation and controls.
//

import XCTest

final class CustomMachineFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor
    func testCaptureCustomMachineFlow() throws {
        let app = XCUIApplication()
        app.launchArguments.append(PulseCueUITestArguments.customMachineFlow)
        app.launch()
        capture(app, "01-today-home")

        // 1. The fixture gives the app an active gym. Enter My Gym from
        //    the stable Settings route rather than the Today card sheet
        //    path that varies with dashboard state.
        app.tabBars.buttons["設定"].tap()
        let settingsMyGymEntry = app.staticTexts["ジムを登録してメニューを生成"]
        XCTAssertTrue(settingsMyGymEntry.waitForExistence(timeout: 8), "Settings My Gym entry not found")
        settingsMyGymEntry.tap()
        capture(app, "02-mygym-home")

        // 2. Into machine selection.
        let selectEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "マシンを選択")).firstMatch
        XCTAssertTrue(selectEntry.waitForExistence(timeout: 6), "Machine selection entry not found")
        selectEntry.tap()
        let selectionNav = app.navigationBars["マシンを選択"]
        XCTAssertTrue(selectionNav.waitForExistence(timeout: 6), "Machine selection screen not reached")
        capture(app, "03-machine-selection")

        // 3. Open the add-custom-machine form.
        let addButton = app.buttons["カスタムマシンを追加"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Custom add button not found")
        addButton.tap()

        let formNav = app.navigationBars["カスタムマシンを追加"]
        XCTAssertTrue(formNav.waitForExistence(timeout: 5), "Custom form did not open")
        capture(app, "04-custom-form-empty")

        // 4. Empty form cannot be saved.
        let saveCreate = app.buttons["追加する"]
        XCTAssertTrue(saveCreate.waitForExistence(timeout: 3), "Create save button missing")
        XCTAssertFalse(saveCreate.isEnabled, "Empty custom-machine form should not save")
        capture(app, "05-custom-form-validation")

        // 5. Fill name + a body part, then save.
        let formName = app.textFields["マシン名"]
        XCTAssertTrue(formName.waitForExistence(timeout: 3), "Name field missing")
        formName.tap()
        formName.typeText("旧型レッグプレス")
        app.buttons["脚"].firstMatch.tap()
        capture(app, "06-custom-form-filled")
        XCTAssertTrue(saveCreate.isEnabled, "Filled custom-machine form should save")
        app.buttons["追加する"].tap()

        // 6. Back on the list, the custom machine is visible.
        XCTAssertTrue(selectionNav.waitForExistence(timeout: 5), "Did not return to selection")
        XCTAssertTrue(app.staticTexts["旧型レッグプレス"].waitForExistence(timeout: 5), "Custom row missing")
        capture(app, "07-custom-in-list")

        // 7. Search returns the custom machine.
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3), "Search field missing")
        search.tap()
        search.typeText("旧型")
        XCTAssertTrue(app.staticTexts["旧型レッグプレス"].waitForExistence(timeout: 3), "Custom search result missing")
        capture(app, "08-custom-search")
        search.typeText("\n")
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 3),
            "Search keyboard did not dismiss"
        )

        // 8. Edit entry is available from the row menu.
        app.buttons["旧型レッグプレス の操作"].tap()
        app.buttons["編集"].tap()
        let editNav = app.navigationBars["カスタムマシンを編集"]
        XCTAssertTrue(editNav.waitForExistence(timeout: 5), "Custom edit form did not open")
        capture(app, "09-custom-edit")
        app.buttons["キャンセル"].tap()

        // 9. Delete requires explicit confirmation.
        XCTAssertTrue(selectionNav.waitForExistence(timeout: 5), "Did not return after edit cancel")
        app.buttons["旧型レッグプレス の操作"].tap()
        app.buttons["削除"].tap()
        XCTAssertTrue(app.buttons["削除"].waitForExistence(timeout: 3), "Delete confirmation missing")
        capture(app, "10-custom-delete-confirmation")
        let deleteCancel = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "キャンセル",
                "Cancel",
                "Close"
            )
        ).firstMatch
        XCTAssertTrue(deleteCancel.waitForExistence(timeout: 3), "Delete cancel button missing")
        deleteCancel.tap()
    }
}

private enum PulseCueUITestArguments {
    static let customMachineFlow = "-pulsecue-ui-test-custom-machine-flow"
}
