import XCTest

/// UI-смоук (решение 9 плана 7): `-uitest-inmemory` даёт чистые хранилища на каждый запуск,
/// поэтому онбординг появляется всегда. Swift Testing UI-тесты не умеет — здесь XCTest.
final class SmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        continueAfterFailure = false
        // настройки — внизу сайдбара; в ландшафте он виден без кнопки сайдбара
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-uitest-inmemory"]
        app.launch()
    }

    @MainActor
    func testSkipOnboardingCreateKeyAndRejectEmptyServer() throws {
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "онбординг не появился")
        skip.tap()

        tap("root.settings")

        // ключ первым: без ключей «Добавить сервер» ведёт на создание ключа
        tap("settings.keys")
        tap("keys.add")
        tap("keys.create")
        tap("newKey.create")
        tap("keys.row")
        let publicKey = app.staticTexts["keyDetail.publicKey"]
        XCTAssertTrue(publicKey.waitForExistence(timeout: 5))
        XCTAssertTrue(publicKey.label.hasPrefix("ssh-ed25519 "), "публичный ключ: \(publicKey.label)")

        back(to: "Ключи")
        back(to: "Настройки")

        tap("settings.servers")
        tap("servers.add")
        let save = app.buttons["serverEdit.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "пустой сервер нельзя сохранить")

        type("bench", into: "serverEdit.label")
        type("dev", into: "serverEdit.user")
        XCTAssertFalse(save.isEnabled, "сервер с пустым адресом нельзя сохранить")

        type("10.0.0.1", into: "serverEdit.host")
        XCTAssertTrue(save.isEnabled, "с адресом сервер сохраняется")
    }

    @MainActor
    private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "нет \(identifier)", file: file, line: line)
        element.tap()
    }

    /// Кнопка «назад» называется заголовком предыдущего экрана.
    @MainActor
    private func back(to title: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.navigationBars.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "нет «назад» в \(title)", file: file, line: line)
        button.tap()
    }

    @MainActor
    private func type(_ text: String, into identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "нет поля \(identifier)", file: file, line: line)
        field.tap()
        field.typeText(text)
    }
}
