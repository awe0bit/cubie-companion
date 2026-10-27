import XCTest

final class CoreNestUITests: XCTestCase {
    private func launch(appearance: String = "light", largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--preview-appearance", appearance]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func explore(_ app: XCUIApplication) {
        let button = app.buttons["welcome-demo"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isHittable { app.scrollViews.firstMatch.swipeUp() }
        button.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["runtime-overview"].firstMatch.waitForExistence(timeout: 15), "Must exercise embedded runtime, not silently pass with native fallback")
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<7 {
            if element.exists && element.isHittable { return }
            let containers = [app.scrollViews.firstMatch, app.collectionViews.firstMatch, app.tables.firstMatch]
            guard let container = containers.first(where: { $0.exists }) else {
                XCTFail("No real scroll container is available")
                return
            }
            container.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    func testWelcomeAndFourNativeTabs() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["welcome-title"].waitForExistence(timeout: 10))
        snapshot("welcome-light")
        explore(app)
        XCTAssertTrue(app.buttons["overview-connect"].exists)
        XCTAssertTrue(app.buttons["overview-controls"].isHittable, "Compact overview should expose controls without scrolling")
        snapshot("overview-light")
        for title in ["服务", "设备", "设置"] {
            app.tabBars.buttons[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            snapshot(title+"-light")
        }
        XCTAssertFalse(app.tabBars.buttons["网络"].exists)
        XCTAssertFalse(app.buttons["device-reboot"].exists)
    }

    func testBindingContainsOnlyQRConfiguration() {
        let app = launch()
        XCTAssertTrue(app.buttons["welcome-connect"].waitForExistence(timeout: 10))
        app.buttons["welcome-connect"].tap()
        XCTAssertTrue(app.buttons["device-binding"].waitForExistence(timeout: 5))
        app.buttons["device-binding"].tap()
        XCTAssertTrue(app.navigationBars["绑定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan-pair"].isHittable)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertFalse(app.buttons["验证并连接"].exists)
        XCTAssertFalse(app.buttons["device-reboot"].exists)
    }

    func testNativeAboutShowsHonestOTAStateAndPackageUpdateEntry() {
        let app = launch()
        explore(app)
        app.buttons["app-about"].tap()
        XCTAssertTrue(app.navigationBars["关于栖核"].waitForExistence(timeout: 5))
        let status = app.staticTexts["ota-status"]
        reveal(status, app: app)
        XCTAssertFalse(status.label.isEmpty)
        let check = app.buttons["release-check"]
        reveal(check, app: app)
        XCTAssertTrue(check.isHittable)
        snapshot("updates-light")
    }

    func testScanPairingSimulatorExplainsCameraLimitation() {
        let app = launch()
        XCTAssertTrue(app.buttons["welcome-connect"].waitForExistence(timeout: 10))
        app.buttons["welcome-connect"].tap()
        XCTAssertTrue(app.buttons["device-binding"].waitForExistence(timeout: 5))
        app.buttons["device-binding"].tap()
        app.buttons["scan-pair"].tap()
        XCTAssertTrue(app.staticTexts["扫码暂不可用"].waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.navigationBars["绑定"].waitForExistence(timeout: 5))
    }

    func testServiceDetailsUseDataAndHideUnavailableActions() {
        let app = launch()
        explore(app)
        app.tabBars.buttons["服务"].tap()
        XCTAssertEqual(app.tabBars.count, 1)
        let panel = app.buttons["service-panel"]
        reveal(panel, app: app)
        panel.tap()
        XCTAssertTrue(app.navigationBars["1Panel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1panel-core.service"].exists)
        XCTAssertTrue(app.staticTexts["采样时间"].exists)
        XCTAssertFalse(app.buttons["查看事件"].exists)
        XCTAssertFalse(app.buttons["重启"].exists)
        XCTAssertFalse(app.buttons["service-refresh"].exists)
        snapshot("service-detail-light")
    }

    func testNativeBarGeometryDoesNotChangeOnScroll() {
        let app = launch()
        explore(app)
        let bar = app.tabBars.firstMatch
        XCTAssertEqual(app.tabBars.count, 1, "Only the system Liquid Glass tab bar may exist")
        let original = bar.frame
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(bar.buttons["概览"].isHittable)
        XCTAssertTrue(bar.buttons["服务"].isHittable)
        XCTAssertTrue(bar.buttons["设备"].isHittable)
        XCTAssertTrue(bar.buttons["设置"].isHittable)
        XCTAssertEqual(bar.buttons.count, 4)
        XCTAssertEqual(bar.frame.height, original.height, accuracy: 1)
        XCTAssertEqual(bar.frame.width, original.width, accuracy: 1)
        XCTAssertEqual(bar.frame.minY, original.minY, accuracy: 1)
        XCTAssertFalse(app.staticTexts["不支持转速反馈"].exists)
        XCTAssertFalse(app.staticTexts["未提供实测数据"].exists)
        snapshot("overview-scrolled-light")
    }

    func testSettingsTabHasWorkingBindingAndUpdateNavigation() {
        let app = launch()
        explore(app)
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 1)
        app.buttons["settings-binding"].tap()
        XCTAssertTrue(app.navigationBars["绑定"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan-pair"].isHittable)
        XCTAssertEqual(app.textFields.count, 0)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings-updates"].tap()
        XCTAssertTrue(app.navigationBars["关于栖核"].waitForExistence(timeout: 5))
    }

    func testServiceSearchFiltersAndDockerDetails() {
        let app = launch()
        explore(app)
        app.tabBars.buttons["服务"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["runtime-services"].waitForExistence(timeout: 15))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("demo-blog")
        XCTAssertEqual(search.value as? String, "demo-blog", "Fast typing must not lose characters when results re-render")
        let container = app.buttons["container-" + String(repeating: "a", count: 64)]
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["service-panel"].exists)
        container.tap()
        XCTAssertTrue(app.navigationBars["demo-blog"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["example/blog:stable"].exists)
        XCTAssertFalse(app.buttons["container-stop"].exists, "Demo must not mutate a real container")
    }

    func testDeviceControlPageShowsLEDsWithoutFakeDemoActions() {
        let app = launch()
        explore(app)
        app.tabBars.buttons["设备"].tap()
        app.buttons["device-controls"].tap()
        XCTAssertTrue(app.navigationBars["设备控制"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["蓝色状态灯"].exists)
        XCTAssertTrue(app.staticTexts["跟随系统"].exists)
        XCTAssertFalse(app.buttons["常亮"].exists)
    }

    func testHardwareInventoryAndRealDetailNavigation() {
        let app = launch()
        explore(app)
        app.tabBars.buttons["设备"].tap()
        XCTAssertTrue(app.navigationBars["设备"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["device-binding"].isHittable)
        let storage = app.buttons["hardware-storage:demo"]
        reveal(storage, app: app)
        snapshot("devices-light")
        storage.tap()
        XCTAssertTrue(app.staticTexts["/dev/mmcblk0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["设备容量"].exists)
        XCTAssertFalse(app.buttons["格式化"].exists)
        snapshot("hardware-detail-light")
    }

    func testDarkNetworkDetailsAndNavigationState() {
        let app = launch(appearance: "dark")
        explore(app)
        snapshot("overview-dark")
        let network = app.buttons["network-details"]
        reveal(network, app: app)
        network.tap()
        XCTAssertTrue(app.staticTexts["校园网络"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["demo-network"].exists)
        snapshot("network-dark")
        app.tabBars.buttons["服务"].tap()
        XCTAssertTrue(app.navigationBars["服务"].waitForExistence(timeout: 5))
        snapshot("services-dark")
    }

    func testLargeTextPairingAndServiceDetailsRemainReachable() {
        let app = launch(largeText: true)
        explore(app)
        app.tabBars.buttons["设备"].tap()
        app.buttons["device-binding"].tap()
        let scan = app.buttons["scan-pair"]
        reveal(scan, app: app)
        XCTAssertTrue(scan.isHittable)
        snapshot("binding-accessibility")
        app.tabBars.buttons["服务"].tap()
        let panel = app.buttons["service-panel"]
        reveal(panel, app: app)
        panel.tap()
        XCTAssertTrue(app.navigationBars["1Panel"].waitForExistence(timeout: 5))
        reveal(app.staticTexts["1panel-core.service"], app: app)
        snapshot("service-accessibility")
    }
}
