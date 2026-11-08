import XCTest

final class OfflineLocateTests: XCTestCase {
    func testEmergencyStopReasonRemainsVisibleToPlayer() {
        let app = XCUIApplication()
        app.launchArguments = ["-role","User","--ui-test-emergency-stop"]
        app.launch()
        app.tabBars.buttons["Locate"].tap()
        for _ in 0..<3 { app.swipeUp() }
        assertStatus("EMERGENCY STOP · measured obstacle 4.0 cm away (5 cm limit)",in:app)
        app.tabBars.buttons["Play"].tap()
        app.tabBars.buttons["Locate"].tap()
        assertStatus("EMERGENCY STOP · measured obstacle 4.0 cm away (5 cm limit)",in:app)
        XCTAssertFalse(app.buttons["Start guided approach"].isEnabled)
    }

    func testMissingHeadingKeepsPhoneLinkConnected() {
        let app = XCUIApplication()
        app.launchArguments = ["-role","Robot","--ui-test-heading-gap"]
        app.launch()
        app.tabBars.buttons["Connect"].tap()
        assertStatus("Phones connected · heading temporarily unavailable",in:app)
        XCTAssertTrue(app.buttons["Disconnect"].exists)
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["Connect phones"].waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["Retry tracking"].isEnabled)
    }

    func testPeerLinkLossKeepsRecoverySessionRunning() {
        let app = XCUIApplication()
        app.launchArguments = ["-role","Robot","--ui-test-peer-link-loss"]
        app.launch()
        app.tabBars.buttons["Connect"].tap()
        assertStatus("Phone link lost · searching automatically",in:app)
        XCTAssertTrue(app.buttons["Disconnect"].exists)
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["Connect phones"].waitForExistence(timeout:5))
        app.tabBars.buttons["Locate"].tap()
        app.tabBars.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons["Connect phones"].exists)
    }

    private func assertStatus(_ value:String,in app:XCUIApplication) {
        let item = app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@ OR value CONTAINS %@",value,value)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout:5),app.debugDescription)
    }

    func testCanPhoneCanNavigateWhilePiIsUnavailable() {
        let app = XCUIApplication()
        // Debug-only harness sends real requests to a closed localhost port, without UWB hardware.
        app.launchArguments = ["-role", "Robot", "--ui-test-offline-pi"]
        app.launch()
        for _ in 0..<3 {
            app.tabBars.buttons["Locate"].tap()
            XCTAssertTrue(app.staticTexts["Find the player"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Other phone not connected"].exists)
            app.tabBars.buttons["Connect"].tap()
            XCTAssertTrue(app.navigationBars["Get connected"].waitForExistence(timeout: 5))
            app.tabBars.buttons["Play"].tap()
            XCTAssertTrue(app.staticTexts["Trashketball"].waitForExistence(timeout: 5))
        }
    }

    func testLidarLabHasUnavailableStateWithoutHardware() {
        let app = XCUIApplication()
        app.launchArguments = ["-role", "Robot"]
        app.launch()
        app.tabBars.buttons["Lab"].tap()
        XCTAssertTrue(app.staticTexts["LiDAR Lab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Local map"].exists)
        XCTAssertTrue(app.staticTexts["Map waiting for live depth and Normal tracking"].exists)
        app.buttons["12 m"].tap()
        app.buttons["Clear map"].tap()
        XCTAssertTrue(app.staticTexts["LiDAR unavailable"].exists)
        XCTAssertFalse(app.buttons["Start LiDAR"].isEnabled)
        app.tabBars.buttons["Connect"].tap()
        XCTAssertTrue(app.navigationBars["Get connected"].waitForExistence(timeout: 5))
    }

    func testGuidedApproachCannotStartWithoutSensors() {
        checkGuidanceUnavailable(role:"Robot")
    }

    func testPlayerHasGuidanceControlsWithoutConnections() {
        checkGuidanceUnavailable(role:"User")
    }

    private func checkGuidanceUnavailable(role:String) {
        let app = XCUIApplication()
        app.launchArguments = ["-role", role]
        app.launch()
        app.tabBars.buttons["Locate"].tap()
        let preview = app.buttons["Preview guidance"]
        for _ in 0..<3 {
            if preview.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Guided approach"].exists)
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(preview.isEnabled)
        XCTAssertFalse(app.buttons["Start guided approach"].isEnabled)
        app.tabBars.buttons["Connect"].tap()
        XCTAssertTrue(app.navigationBars["Get connected"].waitForExistence(timeout: 5))
    }

    func testPlayerLocateOpensWithoutConnections() {
        let app = XCUIApplication()
        app.launchArguments = ["-role", "User"]
        app.launch()
        app.tabBars.buttons["Locate"].tap()
        XCTAssertTrue(app.staticTexts["Find your can"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Other phone not connected"].exists)
        app.tabBars.buttons["Play"].tap()
        XCTAssertTrue(app.staticTexts["Trashketball"].waitForExistence(timeout: 5))
    }
}
