import XCTest

final class NativeVisualTests: XCTestCase {
    private func open(_ style: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-music.appearance", style]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        return app
    }
    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testNativeLightNavigationAndPlayer() {
        let app = open("light")
        capture("01-discover-light-fixture")
        XCTAssertEqual(app.webViews.count, 0)
        app.tabBars.buttons["搜索"].tap(); capture("02-search-light-fixture")
        app.tabBars.buttons["音乐库"].tap(); capture("03-library-light-fixture")
        app.tabBars.buttons["我的"].tap(); capture("04-profile-light-fixture")
        app.staticTexts["暮色里的漫游"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["full-player"].waitForExistence(timeout: 8))
        capture("05-player-light-fixture")
        app.buttons["歌词"].tap(); capture("06-lyrics-light-fixture")
        app.buttons["播放队列"].tap(); capture("07-queue-light-fixture")
    }
    func testNativeDarkAppearance() {
        let app = open("dark")
        capture("08-discover-dark-fixture")
        app.staticTexts["暮色里的漫游"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["full-player"].waitForExistence(timeout: 8))
        capture("09-player-dark-fixture")
    }
}
