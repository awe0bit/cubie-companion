import XCTest

final class CoreNestUITests: XCTestCase {
    private func launch(appearance: String = "light") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--preview-appearance", appearance]
        app.launch()
        return app
    }

    private func explore(_ app: XCUIApplication) {
        let button = app.buttons["welcome-demo"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isHittable { app.scrollViews.firstMatch.swipeUp() }
        button.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWelcomeAndNativeTabs() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["welcome-title"].waitForExistence(timeout: 10))
        snapshot("welcome-light")
        explore(app)
        XCTAssertTrue(app.buttons["overview-connect"].exists)
        snapshot("overview-light")
        for title in ["服务", "网络", "设置"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            snapshot(title+"-light")
        }
        let reboot = app.buttons["device-reboot"]
        for _ in 0..<5 {
            if reboot.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(reboot.waitForExistence(timeout: 5))
        XCTAssertFalse(reboot.isEnabled)
    }

    func testConnectFlowSelectsSettings() {
        let app = launch()
        XCTAssertTrue(app.buttons["welcome-connect"].waitForExistence(timeout: 10))
        app.buttons["welcome-connect"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan-pair"].exists)
        for _ in 0..<3 {
            if app.textFields["设备 HTTPS 地址"].exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.textFields["设备 HTTPS 地址"].exists)
        XCTAssertFalse(app.buttons["验证并连接"].isEnabled)
    }

    func testScanPairingSimulatorExplainsCameraLimitation() {
        let app = launch()
        XCTAssertTrue(app.buttons["welcome-connect"].waitForExistence(timeout: 10))
        app.buttons["welcome-connect"].tap()
        app.buttons["scan-pair"].tap()
        XCTAssertTrue(app.staticTexts["扫码暂不可用"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    }

    func testDarkModeAndNavigationState() {
        let app = launch(appearance: "dark")
        explore(app)
        snapshot("overview-dark")
        app.tabBars.buttons["网络"].tap()
        XCTAssertTrue(app.staticTexts["校园网络"].waitForExistence(timeout: 5))
        snapshot("network-dark")
        app.tabBars.buttons["概览"].tap()
        XCTAssertTrue(app.buttons["overview-connect"].waitForExistence(timeout: 5))
    }
}
