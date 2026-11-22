import XCTest

final class GamePreferencesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPreferencesInLightAppearance() {
        exercisePreferences(appearance: "light", language: "en")
    }

    @MainActor
    func testPreferencesInDarkGermanAppearance() {
        exercisePreferences(appearance: "dark", language: "de")
    }

    @MainActor
    func testRealGameDetailPersistsPreferencesAcrossRelaunchAndRestoresFocus() {
        let app = XCUIApplication()
        app.launchArguments = ["--cloudnow-ui-testing", "--cloudnow-ui-game-preferences-persistence", "--cloudnow-ui-game-preferences-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["CLOUDNOW_DISABLE_LIVE_SERVICES": "1", "CLOUDNOW_TESTING": "1", "CLOUDNOW_UI_TESTING": "1"]
        app.launch()
        openRealGamePreferences(app)
        select(app.buttons["game.preferences.launch"])
        select(app.buttons["game.preferences.launch.option.desktop"])
        select(app.buttons["game.preferences.remote"])
        select(app.buttons["game.preferences.remote.option.mouse"])
        select(app.buttons["game.preferences.done"])
        XCTAssertTrue(waitForFocus(app.buttons["game.preferences.open"]))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--cloudnow-ui-game-preferences-reset" }
        app.launch()
        openRealGamePreferences(app)
        let launch = app.buttons["game.preferences.launch"]
        let remote = app.buttons["game.preferences.remote"]
        XCTAssertEqual(launch.value as? String, "Standard (Desktop)")
        XCTAssertEqual(remote.value as? String, "Controller + Mouse (Siri Remote)")
        select(launch)
        XCTAssertTrue(app.buttons["game.preferences.launch.option.desktop"].isSelected)
        select(app.buttons["game.preferences.launch.option.inherit"])
        select(remote)
        XCTAssertTrue(app.buttons["game.preferences.remote.option.mouse"].isSelected)
        select(app.buttons["game.preferences.remote.option.inherit"])
        XCTAssertEqual(launch.value as? String, "Use app settings")
        XCTAssertEqual(remote.value as? String, "Use app settings")
        select(app.buttons["game.preferences.done"])
        XCTAssertTrue(waitForFocus(app.buttons["game.preferences.open"]))
        attach(app, name: "Real game detail focus after preferences")
    }

    @MainActor
    private func openRealGamePreferences(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Library"].waitForExistence(timeout: 8))
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let racer = app.buttons["Fixture Racer"]
        XCTAssertTrue(racer.waitForExistence(timeout: 5))
        let gridWidth = racer.frame.width
        select(racer, directions: [.down, .left, .right])
        let card = app.buttons.matching(NSPredicate(format: "hasFocus == true AND label == %@", "Fixture Racer")).firstMatch
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            card.exists && card.frame.width > gridWidth * 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        XCUIRemote.shared.press(.select)
        let preferences = app.buttons["game.preferences.open"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 5))
        select(app.buttons["Play"], directions: [.left, .up, .down], activate: false)
        select(preferences, directions: [.right])
        XCTAssertTrue(app.buttons["game.preferences.launch"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func exercisePreferences(appearance: String, language: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "--cloudnow-ui-testing", "--cloudnow-ui-game-preferences",
            "--cloudnow-ui-language", language, "--cloudnow-ui-color-scheme", appearance,
            "-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US",
        ]
        app.launchEnvironment = ["CLOUDNOW_DISABLE_LIVE_SERVICES": "1", "CLOUDNOW_TESTING": "1", "CLOUDNOW_UI_TESTING": "1"]
        app.launch()
        let open = app.buttons["game.preferences.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        select(open)
        let launch = app.buttons["game.preferences.launch"]
        XCTAssertTrue(launch.waitForExistence(timeout: 4))
        select(launch)
        select(app.buttons["game.preferences.launch.option.desktop"])
        XCTAssertEqual(launch.value as? String, "Standard (Desktop)")

        let remote = app.buttons["game.preferences.remote"]
        select(remote)
        select(app.buttons["game.preferences.remote.option.mouse"])
        XCTAssertEqual(launch.value as? String, "Standard (Desktop)")
        let remoteValue = language == "de" ? "Controller + Maus (Siri Remote)" : "Controller + Mouse (Siri Remote)"
        XCTAssertEqual(remote.value as? String, remoteValue)
        select(remote)
        XCTAssertTrue(app.buttons["game.preferences.remote.option.mouse"].isSelected)
        XCUIRemote.shared.press(.menu)
        attach(app, name: "Game preferences \(appearance) \(language)")
        select(app.buttons["game.preferences.done"])
        XCTAssertTrue(open.waitForExistence(timeout: 4))
        XCTAssertTrue(waitForFocus(open))

        select(open)
        XCTAssertEqual(launch.value as? String, "Standard (Desktop)")
        XCTAssertEqual(remote.value as? String, remoteValue)
        select(launch)
        select(app.buttons["game.preferences.launch.option.inherit"])
        select(remote)
        select(app.buttons["game.preferences.remote.option.inherit"])
        let inherited = language == "de" ? "App-Einstellung übernehmen" : "Use app settings"
        XCTAssertEqual(launch.value as? String, inherited)
        XCTAssertEqual(remote.value as? String, inherited)
        attach(app, name: "Game preferences inherited \(appearance) \(language)")
        select(app.buttons["game.preferences.done"])
        XCTAssertTrue(waitForFocus(open))
    }

    @MainActor
    private func select(_ element: XCUIElement, directions: [XCUIRemote.Button] = [.down, .up], activate: Bool = true) {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        for direction in directions {
            for _ in 0 ..< 10 {
                // tvOS Form exposes focus on its Cell, while the identified
                // NavigationLink/Button is an accessible child of that cell.
                let cell = XCUIApplication().cells.containing(.button, identifier: element.identifier).firstMatch
                if element.hasFocus || (cell.exists && cell.hasFocus) {
                    if activate {
                        XCUIRemote.shared.press(.select)
                    }
                    return
                }
                XCUIRemote.shared.press(direction)
            }
        }
        XCTFail("Could not focus \(element.identifier)")
    }

    @MainActor
    private func waitForFocus(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 4) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        // Accessibility values can update before a navigation transition finishes.
        // Wait for unchanged pixels instead of attaching a blended transition frame.
        var previous: Data?
        var stable: XCUIScreenshot?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let screenshot = app.screenshot()
            let pixels = screenshot.pngRepresentation
            defer { previous = pixels }
            guard previous == pixels else { return false }
            stable = screenshot
            return true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 6), .completed)
        guard let stable else { return }
        let attachment = XCTAttachment(screenshot: stable)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
