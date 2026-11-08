import XCTest

final class OfflineLocateTests: XCTestCase {
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
