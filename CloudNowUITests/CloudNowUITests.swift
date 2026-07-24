import XCTest

final class CloudNowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsMainNavigationWithoutAuthentication() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(element("main-navigation", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("home-screen", in: app).exists)
        XCTAssertTrue(app.buttons["Home"].exists)
        XCTAssertTrue(app.buttons["Library"].exists)
        XCTAssertTrue(app.buttons["Store"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
    }

    @MainActor
    func testMainTabsSwitchBetweenLibraryAndStore() {
        let app = makeApp()
        app.launch()

        let library = app.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        selectTab(library, movingRight: 1)
        XCTAssertTrue(element("library-screen", in: app).waitForExistence(timeout: 3))

        let store = app.buttons["Store"]
        XCTAssertTrue(store.waitForExistence(timeout: 3))
        selectTab(store, movingRight: 1)
        XCTAssertTrue(element("store-screen", in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    func testSettingsSurfaceOpensFromMainNavigation() {
        let app = makeApp()
        app.launch()

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        selectTab(settings, movingRight: 3)
        XCTAssertTrue(element("settings-screen", in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--cloudnow-ui-testing",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
        ]
        app.launchEnvironment = [
            "CLOUDNOW_DISABLE_LIVE_SERVICES": "1",
            "CLOUDNOW_TESTING": "1",
            "CLOUDNOW_UI_TESTING": "1",
            "TZ": "UTC",
        ]
        return app
    }

    @MainActor
    private func selectTab(_ tab: XCUIElement, movingRight pressCount: Int) {
        for _ in 0 ..< pressCount where !tab.hasFocus {
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(tab.hasFocus)
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
