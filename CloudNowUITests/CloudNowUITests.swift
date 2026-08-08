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
    func testFreshLaunchOffersBothCloudServices() {
        let app = makeApp(extraArguments: ["--cloudnow-ui-service-chooser"])
        app.launch()

        XCTAssertTrue(element("service-chooser", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["GeForce NOW"].exists)
        XCTAssertTrue(app.buttons["Xbox Cloud Gaming"].exists)
    }

    @MainActor
    func testXboxChoiceDisplaysMicrosoftDeviceCodeLogin() {
        let app = makeApp(extraArguments: ["--cloudnow-ui-service-chooser"])
        app.launch()

        let xbox = app.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xbox.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["GeForce NOW"].hasFocus)
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xbox.hasFocus)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            element("xbox-device-code-login", in: app)
                .waitForExistence(timeout: 5)
        )
        let qrCode = element("xbox-device-code-login.qr", in: app)
        XCTAssertTrue(qrCode.exists)
        XCTAssertEqual(
            qrCode.value as? String,
            "https://www.microsoft.com/link?otc=ABCD-EFGH"
        )
        XCTAssertTrue(element("xbox-device-code-login.code", in: app).exists)
        XCTAssertTrue(app.staticTexts["ABCD-EFGH"].exists)
        XCTAssertTrue(app.buttons["xbox-device-code-login.cancel"].exists)
    }

    @MainActor
    func testConfiguredXboxUsesCloudNowShellAndRoundTripsBetweenServices() {
        let app = makeApp(extraArguments: [
            "--cloudnow-ui-service-chooser",
            "--cloudnow-ui-xbox-configured",
        ])
        app.launch()

        let xbox = app.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xbox.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xbox.hasFocus)
        XCUIRemote.shared.press(.select)

        assertEmptyXboxHome(in: app)

        let xboxProviderSwitcher = app.buttons["Cloud Service"]
        XCTAssertTrue(xboxProviderSwitcher.waitForExistence(timeout: 3))
        XCTAssertEqual(xboxProviderSwitcher.value as? String, "Xbox Cloud Gaming")
        assertLeadingProviderSwitcher(
            xboxProviderSwitcher,
            firstTab: app.buttons["Home"],
            in: app
        )
        let xboxProviderSwitcherFrame = xboxProviderSwitcher.frame
        openProviderMenu(
            xboxProviderSwitcher,
            in: app,
            tabLabels: ["Home", "Browse", "Settings"]
        )
        let switchToGeForceNow = element("provider-option.geforce-now", in: app)
        XCTAssertTrue(switchToGeForceNow.waitForExistence(timeout: 3))
        XCTAssertTrue(switchToGeForceNow.isEnabled)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(element("home-screen", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fixture Racer"].waitForExistence(timeout: 5))

        let geForceNowProviderSwitcher = app.buttons["Cloud Service"]
        XCTAssertTrue(geForceNowProviderSwitcher.waitForExistence(timeout: 3))
        XCTAssertEqual(geForceNowProviderSwitcher.value as? String, "GeForce NOW")
        let geForceNowHome = app.buttons["Home"]
        if !geForceNowHome.hasFocus {
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(geForceNowHome.hasFocus)
        assertLeadingProviderSwitcher(
            geForceNowProviderSwitcher,
            firstTab: geForceNowHome,
            in: app
        )
        XCTAssertEqual(
            geForceNowProviderSwitcher.frame.height,
            xboxProviderSwitcherFrame.height,
            accuracy: 1
        )
        XCTAssertLessThanOrEqual(
            abs(
                geForceNowProviderSwitcher.frame.width
                    - xboxProviderSwitcherFrame.width
            ),
            1
        )
        openProviderMenu(
            geForceNowProviderSwitcher,
            in: app,
            tabLabels: ["Home", "Library", "Store", "Settings"]
        )
        let switchToXbox = element("provider-option.xbox-cloud-gaming", in: app)
        XCTAssertTrue(switchToXbox.waitForExistence(timeout: 3))
        XCTAssertTrue(switchToXbox.isEnabled)
        XCUIRemote.shared.press(.select)

        assertEmptyXboxHome(in: app)
    }

    @MainActor
    func testProviderSwitcherRetractsWithNativeNavigationInBothModes() {
        let geForceNowApp = makeApp()
        geForceNowApp.launch()

        openSettings(in: geForceNowApp)
        assertProviderSwitcherFollowsNativeNavigation(
            in: geForceNowApp,
            selectedTab: geForceNowApp.buttons["Settings"]
        )
        geForceNowApp.terminate()

        let xboxApp = makeApp(extraArguments: [
            "--cloudnow-ui-service-chooser",
            "--cloudnow-ui-xbox-configured",
        ])
        xboxApp.launch()

        let xboxChoice = xboxApp.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xboxChoice.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xboxChoice.hasFocus)
        XCUIRemote.shared.press(.select)

        let xboxSettings = xboxApp.buttons["Settings"]
        XCTAssertTrue(xboxSettings.waitForExistence(timeout: 5))
        selectTab(xboxSettings, movingRight: 2)
        assertProviderSwitcherFollowsNativeNavigation(
            in: xboxApp,
            selectedTab: xboxSettings
        )
    }

    @MainActor
    func testConfiguredXboxLaunchCanBeCancelledBeforeConnection() {
        let app = makeApp(extraArguments: [
            "--cloudnow-ui-service-chooser",
            "--cloudnow-ui-xbox-configured",
        ])
        app.launch()

        let xbox = app.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xbox.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xbox.hasFocus)
        XCUIRemote.shared.press(.select)

        assertEmptyXboxHome(in: app)
        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        selectTab(browse, movingRight: 1)
        XCTAssertTrue(
            element("xbox-browse-screen", in: app)
                .waitForExistence(timeout: 3)
        )

        let racer = app.buttons["Fixture Racer"]
        XCTAssertTrue(racer.waitForExistence(timeout: 5))
        focusAndSelect(
            racer,
            directions: [.down, .left, .right],
            pressesPerDirection: 8
        )
        let carouselRacer = focusedButton(labeled: "Fixture Racer", in: app)
        XCTAssertTrue(carouselRacer.waitForExistence(timeout: 3))
        XCUIRemote.shared.press(.select)

        let play = element("xbox-game.play.FIXTURE-RACER", in: app)
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        focusAndSelect(
            play,
            directions: [.down, .up, .left, .right],
            pressesPerDirection: 6
        )
        XCTAssertTrue(
            element("xbox-stream-state.requesting-access", in: app)
                .waitForExistence(timeout: 5)
        )

        let cancel = element("xbox-stream.cancel", in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        focusAndSelect(
            cancel,
            directions: [.down, .up, .left, .right],
            pressesPerDirection: 4
        )
        XCTAssertTrue(
            element("xbox-browse-screen", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(waitForFocus(racer))
    }

    @MainActor
    func testXboxFreeWithAdsAndMembershipAreExposed() {
        let app = makeApp(extraArguments: [
            "--cloudnow-ui-service-chooser",
            "--cloudnow-ui-xbox-configured",
        ])
        app.launch()

        let xbox = app.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xbox.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xbox.hasFocus)
        XCUIRemote.shared.press(.select)

        assertEmptyXboxHome(in: app)

        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        selectTab(browse, movingRight: 1)
        XCTAssertTrue(
            element("xbox-browse-screen", in: app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(element("catalog-result-count", in: app).exists)
        XCTAssertTrue(app.buttons["catalog-sort-menu"].exists)
        XCTAssertTrue(app.buttons["catalog-filter-button"].exists)
        XCTAssertTrue(app.buttons["reloadXboxCloudCatalogButton"].exists)

        let freeGame = element(
            "xbox-game-card.FIXTURE-ADVENTURE.freeWithAds.fixture-adventure",
            in: app
        )
        XCTAssertTrue(freeGame.waitForExistence(timeout: 3))
        focusAndSelect(
            freeGame,
            directions: [.down, .left, .right],
            pressesPerDirection: 8
        )
        XCTAssertTrue(
            element("xbox-game-carousel", in: app)
                .waitForExistence(timeout: 3)
        )
        let freeCarouselCard = focusedButton(
            labeled: "Fixture Adventure",
            in: app
        )
        XCTAssertTrue(freeCarouselCard.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFocus(freeCarouselCard))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(
            element("xbox-game.play.FIXTURE-ADVENTURE", in: app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.staticTexts[
                "A deterministic adventure fixture with an ad-supported route."
            ].exists
        )
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(freeGame))

        let lockedPreview = element(
            "xbox-game-card.FIXTURE-PREVIEW-LOCKED.freeWithAds.fixture-preview-locked",
            in: app
        )
        XCTAssertTrue(lockedPreview.waitForExistence(timeout: 3))
        focusAndSelect(
            lockedPreview,
            directions: [.right, .left],
            pressesPerDirection: 3
        )
        let lockedCarouselCard = focusedButton(
            labeled: "Fixture Preview Locked",
            in: app
        )
        XCTAssertTrue(lockedCarouselCard.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFocus(lockedCarouselCard))
        XCUIRemote.shared.press(.select)
        let unavailablePlay = element(
            "xbox-game.play.FIXTURE-PREVIEW-LOCKED",
            in: app
        )
        XCTAssertTrue(unavailablePlay.waitForExistence(timeout: 3))
        XCTAssertFalse(unavailablePlay.isEnabled)
        XCTAssertTrue(unavailablePlay.label.contains("Not eligible"))
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(waitForFocus(lockedPreview))

        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        focusAndSelect(
            settings,
            directions: [.up, .right, .left],
            pressesPerDirection: 12
        )

        let membership = element("xbox-settings.membership", in: app)
        for _ in 0 ..< 50 where !membership.exists {
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(membership.waitForExistence(timeout: 3))
        XCTAssertTrue(
            "\(membership.label) \(accessibilityValue(of: membership))"
                .contains("Game Pass Ultimate")
        )
    }

    @MainActor
    func testXboxBrowseExposesProviderAppropriateFilters() {
        let app = makeApp(extraArguments: [
            "--cloudnow-ui-service-chooser",
            "--cloudnow-ui-xbox-configured",
        ])
        app.launch()

        let xbox = app.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xbox.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xbox.hasFocus)
        XCUIRemote.shared.press(.select)

        assertEmptyXboxHome(in: app)
        let browse = app.tabBars.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        selectTab(browse, movingRight: 1)

        let filters = app.buttons["catalog-filter-button"]
        XCTAssertTrue(filters.waitForExistence(timeout: 3))
        let filterFocusDirections: [XCUIRemote.Button] = [
            .down,
            .down,
            .left,
        ]
        for direction in filterFocusDirections {
            if filters.hasFocus {
                break
            }
            XCUIRemote.shared.press(direction)
        }
        XCTAssertTrue(filters.hasFocus)
        XCUIRemote.shared.press(.select)

        XCTAssertTrue(
            element("xbox-catalog-filter-sheet", in: app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(filterOptionButton(labeled: "Favorites", in: app).exists)
        XCTAssertTrue(filterOptionButton(labeled: "Game Pass", in: app).exists)
        XCTAssertTrue(filterOptionButton(labeled: "Free with ads", in: app).exists)
        XCTAssertTrue(filterOptionButton(labeled: "Owned", in: app).exists)
        XCTAssertTrue(filterOptionButton(labeled: "Controller", in: app).exists)
        XCTAssertTrue(filterOptionButton(labeled: "Touch", in: app).exists)
        XCTAssertTrue(
            filterOptionButton(labeled: "Keyboard & Mouse", in: app).exists
        )
        XCTAssertTrue(filterOptionButton(labeled: "Racing", in: app).exists)
        XCTAssertTrue(filterOptionButton(labeled: "Adventure", in: app).exists)
        XCTAssertTrue(filterOptionButton(labeled: "Puzzle", in: app).exists)
    }

    @MainActor
    func testCloudServiceSettingsOnlyShowsOtherProvider() {
        let app = makeApp(extraArguments: ["--cloudnow-ui-service-chooser"])
        app.launch()

        let geForceNow = app.buttons["GeForce NOW"]
        XCTAssertTrue(geForceNow.waitForExistence(timeout: 8))
        XCTAssertTrue(geForceNow.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(element("main-navigation", in: app).waitForExistence(timeout: 5))

        openSettings(in: app)
        XCTAssertTrue(
            app.buttons["service-switch.xbox-cloud-gaming"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["service-switcher"].exists)
        XCTAssertFalse(app.buttons["Choose Another Service"].exists)
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
    func testGeForceNowLibraryCarouselNavigatesCollapsesAndRestoresFocus() {
        let app = makeApp()
        app.launch()

        let library = app.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        selectTab(library, movingRight: 1)
        XCTAssertTrue(
            element("library-screen", in: app)
                .waitForExistence(timeout: 3)
        )

        let racer = app.buttons["Fixture Racer"]
        let strategy = app.buttons["Fixture Strategy"]
        XCTAssertTrue(racer.waitForExistence(timeout: 3))
        XCTAssertTrue(strategy.waitForExistence(timeout: 3))
        let strategyGridFrame = strategy.frame

        focusAndSelect(
            racer,
            directions: [.down, .left, .right],
            pressesPerDirection: 12
        )
        XCTAssertTrue(
            focusedButton(labeled: "Fixture Racer", in: app)
                .waitForExistence(timeout: 3)
        )

        XCUIRemote.shared.press(.right)
        let carouselStrategy = focusedButton(
            labeled: "Fixture Strategy",
            in: app
        )
        XCTAssertTrue(carouselStrategy.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(
            carouselStrategy.frame.width,
            strategyGridFrame.width * 2
        )

        XCUIRemote.shared.press(.select)
        let play = app.buttons["Play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForFocus(play))

        XCUIRemote.shared.press(.menu)
        let collapsedStrategy = focusedButton(
            labeled: "Fixture Strategy",
            in: app
        )
        XCTAssertTrue(collapsedStrategy.waitForExistence(timeout: 3))
        let collapsedStrategyFrame = collapsedStrategy.frame
        XCTAssertGreaterThan(
            collapsedStrategyFrame.width,
            strategyGridFrame.width * 2
        )

        XCUIRemote.shared.press(.menu)
        let restoredStrategy = focusedButton(
            labeled: "Fixture Strategy",
            in: app
        )
        XCTAssertTrue(restoredStrategy.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(
            restoredStrategy.frame.width,
            strategyGridFrame.width
        )
        XCTAssertLessThan(
            restoredStrategy.frame.width,
            collapsedStrategyFrame.width
        )
        XCTAssertEqual(
            restoredStrategy.frame.midX,
            strategyGridFrame.midX,
            accuracy: 1
        )
    }

    @MainActor
    func testSettingsSurfaceOpensFromMainNavigation() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        XCTAssertTrue(element("settings-screen", in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    func testStreamQualityUsesCloudNowRowsInBothModes() {
        let geForceNowApp = makeApp()
        geForceNowApp.launch()
        openSettings(in: geForceNowApp)
        let geForceNowResolution = element(
            "settings.stream-quality.resolution",
            in: geForceNowApp
        )
        let geForceNowCodec = element(
            "settings.stream-quality.codec",
            in: geForceNowApp
        )
        let geForceNowLanguage = element(
            "settings.stream-quality.game-language",
            in: geForceNowApp
        )
        XCTAssertTrue(geForceNowResolution.waitForExistence(timeout: 3))
        XCTAssertTrue(geForceNowResolution.isEnabled)
        XCTAssertTrue(geForceNowCodec.waitForExistence(timeout: 3))
        XCTAssertTrue(geForceNowCodec.isEnabled)
        XCTAssertTrue(geForceNowLanguage.waitForExistence(timeout: 3))
        XCTAssertTrue(geForceNowLanguage.isEnabled)
        geForceNowApp.terminate()

        let xboxApp = makeApp(extraArguments: [
            "--cloudnow-ui-service-chooser",
            "--cloudnow-ui-xbox-configured",
        ])
        xboxApp.launch()
        let xboxChoice = xboxApp.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xboxChoice.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xboxChoice.hasFocus)
        XCUIRemote.shared.press(.select)

        let xboxSettings = xboxApp.buttons["Settings"]
        XCTAssertTrue(xboxSettings.waitForExistence(timeout: 5))
        selectTab(xboxSettings, movingRight: 2)
        let xboxResolution = element(
            "settings.stream-quality.resolution",
            in: xboxApp
        )
        let xboxLanguage = element(
            "settings.stream-quality.game-language",
            in: xboxApp
        )
        XCTAssertTrue(xboxResolution.waitForExistence(timeout: 3))
        XCTAssertTrue(xboxResolution.isEnabled)
        XCTAssertTrue(xboxLanguage.waitForExistence(timeout: 3))
        XCTAssertTrue(xboxLanguage.isEnabled)
        XCTAssertFalse(
            element("settings.stream-quality.frame-rate", in: xboxApp).exists
        )
        XCTAssertFalse(
            element("settings.stream-quality.codec", in: xboxApp).exists
        )
        XCTAssertFalse(xboxApp.buttons["Frame Rate"].exists)
        XCTAssertFalse(xboxApp.buttons["Codec"].exists)
        XCTAssertFalse(xboxApp.buttons["Color Mode"].exists)
        XCTAssertFalse(xboxApp.buttons["Audio Format"].exists)
        XCTAssertFalse(xboxApp.buttons["Max Bitrate"].exists)

        let currentResolutionText =
            "\(xboxResolution.label) \(accessibilityValue(of: xboxResolution))"
        let targetResolution = currentResolutionText.contains("1080p")
            ? "720p"
            : "1080p"

        // SwiftUI's native tvOS Picker does not expose `hasFocus` on its
        // identified accessibility node. The deterministic Settings fixture
        // places it one focus move below the selected Settings tab.
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)

        let automaticOption = xboxApp.cells
            .matching(NSPredicate(format: "label == %@", "Automatic"))
            .firstMatch
        let fullHDOption = xboxApp.cells
            .matching(NSPredicate(format: "label == %@", "1080p"))
            .firstMatch
        let hdOption = xboxApp.cells
            .matching(NSPredicate(format: "label == %@", "720p"))
            .firstMatch
        let hdHighQualityOption = xboxApp.cells
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "720p",
                    "HQ"
                )
            )
            .firstMatch
        let fullHDHighQualityOption = xboxApp.cells
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS %@",
                    "1080p",
                    "HQ"
                )
            )
            .firstMatch
        let maxQualityOption = xboxApp.cells
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ AND label CONTAINS[c] %@",
                    "1440p",
                    "max"
                )
            )
            .firstMatch
        XCTAssertTrue(automaticOption.waitForExistence(timeout: 3))
        XCTAssertTrue(fullHDOption.waitForExistence(timeout: 3))
        XCTAssertTrue(hdOption.waitForExistence(timeout: 3))
        XCTAssertTrue(hdHighQualityOption.waitForExistence(timeout: 3))
        XCTAssertTrue(fullHDHighQualityOption.waitForExistence(timeout: 3))
        XCTAssertTrue(maxQualityOption.waitForExistence(timeout: 3))
        XCTAssertFalse(
            xboxApp.cells
                .matching(NSPredicate(format: "label == %@", "Standard"))
                .firstMatch.exists
        )
        XCTAssertFalse(
            xboxApp.cells
                .matching(NSPredicate(format: "label == %@", "Game Pass Ultimate"))
                .firstMatch.exists
        )

        let targetOption = targetResolution == "720p" ? hdOption : fullHDOption
        XCTAssertTrue(targetOption.isEnabled)
        focus(
            targetOption,
            directions: [.down, .up],
            pressesPerDirection: 12
        )
        XCUIRemote.shared.press(.select)

        let selectedResolution = element(
            "settings.stream-quality.resolution",
            in: xboxApp
        )
        XCTAssertTrue(selectedResolution.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitForAccessibilityText(
                targetResolution,
                in: selectedResolution
            )
        )

        xboxApp.terminate()
        xboxApp.launch()

        let relaunchedXboxChoice = xboxApp.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(relaunchedXboxChoice.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(relaunchedXboxChoice.hasFocus)
        XCUIRemote.shared.press(.select)

        let relaunchedXboxSettings = xboxApp.buttons["Settings"]
        XCTAssertTrue(relaunchedXboxSettings.waitForExistence(timeout: 5))
        selectTab(relaunchedXboxSettings, movingRight: 2)

        let persistedResolution = element(
            "settings.stream-quality.resolution",
            in: xboxApp
        )
        XCTAssertTrue(persistedResolution.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitForAccessibilityText(
                targetResolution,
                in: persistedResolution
            )
        )
    }

    @MainActor
    func testControllerSettingsUseTheSameCloudNowRowsInBothModes() {
        let geForceNowApp = makeApp()
        geForceNowApp.launch()
        openSettings(in: geForceNowApp)
        XCTAssertTrue(
            element("settings-screen", in: geForceNowApp)
                .waitForExistence(timeout: 3)
        )

        let geForceNowRumble = geForceNowApp.switches["settings.rumble-enabled"]
        let geForceNowIntensity = geForceNowApp.staticTexts["settings.rumble-intensity"]
        let geForceNowDeadzone = geForceNowApp.staticTexts["settings.controller-deadzone"]
        XCTAssertTrue(geForceNowRumble.waitForExistence(timeout: 3))
        XCTAssertTrue(geForceNowIntensity.waitForExistence(timeout: 3))
        XCTAssertTrue(geForceNowDeadzone.waitForExistence(timeout: 3))
        let rumbleLabel = geForceNowRumble.label
        XCTAssertTrue(geForceNowIntensity.label.hasSuffix("×"))
        XCTAssertTrue(geForceNowDeadzone.label.hasSuffix("%"))
        geForceNowApp.terminate()

        let xboxApp = makeApp(extraArguments: [
            "--cloudnow-ui-service-chooser",
            "--cloudnow-ui-xbox-configured",
        ])
        xboxApp.launch()
        let xboxChoice = xboxApp.buttons["Xbox Cloud Gaming"]
        XCTAssertTrue(xboxChoice.waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(xboxChoice.hasFocus)
        XCUIRemote.shared.press(.select)

        let xboxSettings = xboxApp.buttons["Settings"]
        XCTAssertTrue(xboxSettings.waitForExistence(timeout: 5))
        selectTab(xboxSettings, movingRight: 2)
        XCTAssertTrue(
            element("xbox-settings-screen", in: xboxApp)
                .waitForExistence(timeout: 3)
        )

        let xboxRumble = xboxApp.switches["settings.rumble-enabled"]
        let xboxIntensity = xboxApp.staticTexts["settings.rumble-intensity"]
        let xboxDeadzone = xboxApp.staticTexts["settings.controller-deadzone"]
        XCTAssertTrue(xboxRumble.waitForExistence(timeout: 3))
        XCTAssertTrue(xboxIntensity.waitForExistence(timeout: 3))
        XCTAssertTrue(xboxDeadzone.waitForExistence(timeout: 3))
        XCTAssertEqual(xboxRumble.label, rumbleLabel)
        XCTAssertTrue(xboxIntensity.label.hasSuffix("%"))
        XCTAssertTrue(xboxDeadzone.label.hasSuffix("%"))
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
    private func assertEmptyXboxHome(in app: XCUIApplication) {
        XCTAssertTrue(
            element("xbox-home-screen", in: app)
                .waitForExistence(timeout: 5)
        )
        let emptyTitle = app.staticTexts["Nothing here yet"]
        XCTAssertTrue(emptyTitle.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(
            visibleFraction(of: emptyTitle, inside: app.windows.firstMatch.frame),
            0.9
        )
        XCTAssertFalse(app.buttons["Fixture Racer"].exists)
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

    /// SwiftUI's native tvOS `Menu` exposes its button to accessibility, but
    /// XCTest does not report `hasFocus` for that node even while the system
    /// focus effect is visible. Focus can also restore to this menu after a
    /// mode transition. Opening it and observing its options is the reliable
    /// accessibility-level assertion for this system control.
    @MainActor
    private func openProviderMenu(
        _ menu: XCUIElement,
        in app: XCUIApplication,
        tabLabels: [String]
    ) {
        XCTAssertTrue(menu.exists && menu.isEnabled)

        let focusedElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
            .firstMatch
        if !focusedElement.exists || menu.hasFocus {
            XCUIRemote.shared.press(.select)
            return
        }

        let firstTab = app.buttons[tabLabels[0]]
        if !firstTab.hasFocus {
            // Focus normally stays on the provider menu across a mode switch,
            // but XCTest does not expose `hasFocus` for a native tvOS Menu.
            // Moving right is a safe probe because the menu sits immediately
            // before the first native tab in the focus row.
            XCUIRemote.shared.press(.right)
        }
        for _ in 0 ..< 8 {
            if firstTab.hasFocus {
                break
            }
            XCUIRemote.shared.press(.up)
        }
        for _ in 0 ..< tabLabels.count {
            if firstTab.hasFocus {
                break
            }
            XCUIRemote.shared.press(.left)
        }
        XCTAssertTrue(firstTab.hasFocus)

        XCUIRemote.shared.press(.left)
        XCTAssertTrue(waitForFocusLoss(firstTab, timeout: 3))
        XCUIRemote.shared.press(.select)
    }

    @MainActor
    private func assertLeadingProviderSwitcher(
        _ switcher: XCUIElement,
        firstTab: XCUIElement,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(firstTab.exists)
        let switcherFrame = switcher.frame
        let firstTabFrame = firstTab.frame
        let windowFrame = app.windows.firstMatch.frame

        XCTAssertLessThanOrEqual(switcherFrame.maxX + 24, firstTabFrame.minX)
        XCTAssertEqual(switcherFrame.midY, firstTabFrame.midY, accuracy: 12)
        // XCTest exposes the native tab label, while its focus chrome extends
        // about 30 points per side. Compare equivalent visual footprints.
        let nativeTabVisualWidth = firstTabFrame.width + 60
        XCTAssertGreaterThanOrEqual(
            switcherFrame.width / nativeTabVisualWidth,
            1.05
        )
        XCTAssertLessThanOrEqual(
            switcherFrame.width / nativeTabVisualWidth,
            1.25
        )
        XCTAssertLessThan(switcherFrame.width / windowFrame.width, 0.13)
    }

    @MainActor
    private func assertProviderSwitcherFollowsNativeNavigation(
        in app: XCUIApplication,
        selectedTab: XCUIElement
    ) {
        let switcher = app.buttons["Cloud Service"]
        let bottomSetting = element("settings.sign-out", in: app)
        let focusedBottomSetting = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "hasFocus == true AND label == %@",
                "Sign Out"
            ))
            .firstMatch
        for _ in 0 ..< 12 {
            if selectedTab.hasFocus {
                break
            }
            XCUIRemote.shared.press(.up)
        }
        for _ in 0 ..< 5 {
            if selectedTab.hasFocus {
                break
            }
            XCUIRemote.shared.press(.right)
        }
        let initialFocusedElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
            .firstMatch
        XCTAssertTrue(
            selectedTab.hasFocus,
            "Expected native tab focus; current focus: \(initialFocusedElement.debugDescription)"
        )
        XCTAssertTrue(switcher.waitForExistence(timeout: 3))

        for _ in 0 ..< 80 {
            if focusedBottomSetting.exists {
                break
            }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(bottomSetting.exists)
        let focusedElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true"))
            .firstMatch
        XCTAssertTrue(
            focusedBottomSetting.exists,
            "Expected Sign Out focus; current focus: \(focusedElement.debugDescription)"
        )
        XCTAssertFalse(selectedTab.hasFocus)
        let nativeNavigationRetracted = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.maxY <= 1
            },
            object: selectedTab
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [nativeNavigationRetracted], timeout: 3),
            .completed
        )
        let switcherRetracted = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return !element.exists || element.frame.maxY <= 1
            },
            object: switcher
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [switcherRetracted], timeout: 3),
            .completed
        )

        let windowFrame = app.windows.firstMatch.frame
        for step in 1 ... 80 {
            if selectedTab.hasFocus {
                break
            }
            XCUIRemote.shared.press(.up)
            let nativeVisibleFraction = visibleFraction(
                of: selectedTab,
                inside: windowFrame
            )
            let providerVisibleFraction = visibleFraction(
                of: switcher,
                inside: windowFrame
            )
            if providerVisibleFraction > nativeVisibleFraction + 0.1 {
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Provider switcher led native navigation at step \(step)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTFail(
                    "Provider visibility \(providerVisibleFraction) exceeded native navigation visibility \(nativeVisibleFraction) at upward step \(step)"
                )
                return
            }
        }
        for _ in 0 ..< 5 {
            if selectedTab.hasFocus {
                break
            }
            XCUIRemote.shared.press(.right)
        }
        XCTAssertTrue(selectedTab.hasFocus)
        let nativeNavigationReturned = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.frame.minY > 1
            },
            object: selectedTab
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [nativeNavigationReturned], timeout: 3),
            .completed
        )
        XCTAssertTrue(switcher.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(switcher.frame.minY, 1)
        XCTAssertEqual(switcher.frame.midY, selectedTab.frame.midY, accuracy: 12)
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
    private func waitForAccessibilityText(
        _ text: String,
        in element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                let value = element.value as? String ?? ""
                return "\(element.label) \(value)".contains(text)
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
    private func focusedButton(
        labeled label: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(
                format: "label == %@ AND hasFocus == true",
                label
            ))
            .firstMatch
    }

    @MainActor
    private func filterOptionButton(
        labeled label: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                label,
                "\(label),"
            ))
            .firstMatch
    }

    @MainActor
    private func waitForFocusLoss(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasFocus == false"),
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
