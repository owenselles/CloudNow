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
        let remoteValue = remote.value as? String
        XCTAssertNotNil(remoteValue)
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
        attach(app, name: "Game preferences inherited \(appearance) \(language)")
        select(app.buttons["game.preferences.done"])
        XCTAssertTrue(waitForFocus(open))
    }

    @MainActor
    private func select(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        for direction: XCUIRemote.Button in [.down, .up] {
            for _ in 0 ..< 10 {
                // tvOS Form exposes focus on its Cell, while the identified
                // NavigationLink/Button is an accessible child of that cell.
                let cell = XCUIApplication().cells.containing(.button, identifier: element.identifier).firstMatch
                if element.hasFocus || (cell.exists && cell.hasFocus) {
                    XCUIRemote.shared.press(.select)
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
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
