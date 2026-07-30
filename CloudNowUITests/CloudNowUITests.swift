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

        openSettings(in: app)
        XCTAssertTrue(element("settings-screen", in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    func testLibraryRefreshShowsProviderOutcomesAndRetry() {
        let app = makeApp(extraArguments: ["--cloudnow-ui-library-refresh-partial"])
        app.launch()

        openLibraryRefreshSheet(in: app)

        let steam = element("libraryRefreshProvider.STEAM", in: app)
        XCTAssertTrue(steam.exists)
        let initialSteamSync = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS '42'"),
            object: steam
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [initialSteamSync], timeout: 5),
            .completed
        )
        XCTAssertTrue(element("libraryRefreshProvider.XBOX", in: app).exists)
        XCTAssertTrue(element("libraryRefreshProvider.EPIC", in: app).exists)
        XCTAssertTrue(element("libraryRefreshFinalImport", in: app).exists)
        XCTAssertTrue(
            element("libraryRefreshSummary", in: app)
                .waitForExistence(timeout: 5)
        )
        let retryButton = app.buttons["libraryRefreshRetryFailedButton"]
        XCTAssertTrue(retryButton.exists)
        XCTAssertTrue(waitForFocus(retryButton))
        XCTAssertTrue(app.buttons["libraryRefreshDoneButton"].exists)
        XCTAssertFalse(app.buttons["Cancel"].exists)

        focusAndSelect(
            retryButton,
            directions: [.up, .right, .left],
            pressesPerDirection: 20
        )
        let retriedXbox = element("libraryRefreshProvider.XBOX", in: app)
        let syncedExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS '55'"),
            object: retriedXbox
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [syncedExpectation], timeout: 5),
            .completed
        )
        XCTAssertFalse(retryButton.exists)
        XCTAssertTrue(element("libraryRefreshSummary", in: app).exists)
        let doneButton = app.buttons["libraryRefreshDoneButton"]
        XCTAssertTrue(doneButton.exists)
        XCTAssertTrue(waitForFocus(doneButton))
    }

    @MainActor
    func testLibraryRefreshUsesFullViewportAndScrollsLongProviderList() {
        let app = makeApp(extraArguments: ["--cloudnow-ui-library-refresh-long-list"])
        app.launch()

        openLibraryRefreshSheet(in: app)

        let viewport = app.scrollViews["libraryRefreshProgressSheet"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertGreaterThan(viewport.frame.width / windowFrame.width, 0.85)
        XCTAssertGreaterThan(viewport.frame.height / windowFrame.height, 0.75)
        XCTAssertTrue(element("libraryRefreshHeader", in: app).exists)
        XCTAssertTrue(
            waitForFocus(app.buttons["libraryRefreshCloseButton"])
        )
        XCTAssertTrue(
            accessibilityValue(
                of: element("libraryRefreshOverallProgress", in: app)
            ).contains("11 of 13 steps complete")
        )

        let finalProvider = element("libraryRefreshProvider.HOYOVERSE", in: app)
        focus(
            finalProvider,
            directions: [.down],
            pressesPerDirection: 30
        )
        XCTAssertGreaterThan(
            visibleFraction(of: finalProvider, inside: windowFrame),
            0.9
        )

        let finalImport = element("libraryRefreshFinalImport", in: app)
        focus(
            finalImport,
            directions: [.down],
            pressesPerDirection: 5
        )
        XCTAssertGreaterThan(
            visibleFraction(of: finalImport, inside: windowFrame),
            0.9
        )
        XCTAssertTrue(accessibilityValue(of: finalImport).contains("Queued"))
    }

    @MainActor
    func testClosingAndReopeningKeepsActiveRefreshProgress() {
        let app = makeApp(extraArguments: ["--cloudnow-ui-library-refresh-running"])
        app.launch()

        openLibraryRefreshSheet(in: app)
        let closeButton = app.buttons["libraryRefreshCloseButton"]
        XCTAssertTrue(closeButton.exists)
        XCTAssertTrue(waitForFocus(closeButton))
        XCTAssertTrue(
            accessibilityValue(
                of: element("libraryRefreshProvider.STEAM", in: app)
            ).contains("Syncing")
        )
        XCTAssertTrue(
            accessibilityValue(
                of: element("libraryRefreshFinalImport", in: app)
            ).contains("Queued")
        )

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(element("settings-screen", in: app).waitForExistence(timeout: 3))
        openLibraryRefreshSheetFromSettings(in: app)

        XCTAssertTrue(app.buttons["libraryRefreshCloseButton"].exists)
        XCTAssertTrue(
            accessibilityValue(
                of: element("libraryRefreshProvider.STEAM", in: app)
            ).contains("Syncing")
        )
    }

    @MainActor
    func testRefreshWithoutConnectedProvidersShowsDirectImportResult() {
        let app = makeApp(extraArguments: ["--cloudnow-ui-library-refresh-empty"])
        app.launch()

        openLibraryRefreshSheet(in: app)

        XCTAssertTrue(element("libraryRefreshNoConnectedProviders", in: app).exists)
        XCTAssertTrue(element("libraryRefreshFinalImport", in: app).exists)
        XCTAssertTrue(element("libraryRefreshSummary", in: app).exists)
        let doneButton = app.buttons["libraryRefreshDoneButton"]
        XCTAssertTrue(doneButton.exists)
        XCTAssertTrue(waitForFocus(doneButton))

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            element("settings-screen", in: app)
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    private func makeApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--cloudnow-ui-testing",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
        ] + extraArguments
        app.launchEnvironment = [
            "CLOUDNOW_DISABLE_LIVE_SERVICES": "1",
            "CLOUDNOW_TESTING": "1",
            "CLOUDNOW_UI_TESTING": "1",
            "TZ": "UTC",
        ]
        return app
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        selectTab(settings, movingRight: 3)
    }

    @MainActor
    private func openLibraryRefreshSheet(in app: XCUIApplication) {
        openSettings(in: app)
        XCTAssertTrue(element("settings-screen", in: app).waitForExistence(timeout: 3))
        openLibraryRefreshSheetFromSettings(in: app)
    }

    @MainActor
    private func openLibraryRefreshSheetFromSettings(in app: XCUIApplication) {
        let button = app.buttons["libraryRefreshButton"]
        let focusedRefreshRow = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "hasFocus == true AND label CONTAINS %@",
                "Refresh Library"
            ))
            .firstMatch
        for _ in 0 ..< 80 {
            if focusedRefreshRow.exists {
                break
            }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(button.exists)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(focusedRefreshRow.exists)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            app.scrollViews["libraryRefreshProgressSheet"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    private func selectTab(_ tab: XCUIElement, movingRight pressCount: Int) {
        for _ in 0 ..< pressCount {
            if tab.hasFocus {
                break
            }
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(tab.hasFocus)
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func focusAndSelect(
        _ element: XCUIElement,
        directions: [XCUIRemote.Button],
        pressesPerDirection: Int
    ) {
        focus(
            element,
            directions: directions,
            pressesPerDirection: pressesPerDirection
        )
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func focus(
        _ element: XCUIElement,
        directions: [XCUIRemote.Button],
        pressesPerDirection: Int
    ) {
        for direction in directions {
            for _ in 0 ..< pressesPerDirection {
                if element.exists, element.hasFocus {
                    break
                }
                XCUIRemote.shared.press(direction)
            }
            if element.exists, element.hasFocus {
                break
            }
        }
        XCTAssertTrue(element.exists && element.hasFocus)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func accessibilityValue(of element: XCUIElement) -> String {
        element.value as? String ?? ""
    }

    @MainActor
    private func waitForFocus(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func visibleFraction(
        of element: XCUIElement,
        inside containerFrame: CGRect
    ) -> CGFloat {
        let elementFrame = element.frame
        guard elementFrame.width > 0, elementFrame.height > 0 else { return 0 }
        let intersection = elementFrame.intersection(containerFrame)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
            / (elementFrame.width * elementFrame.height)
    }
}
