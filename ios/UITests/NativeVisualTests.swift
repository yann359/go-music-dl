import XCTest

final class NativeVisualTests: XCTestCase {
    func testRealNativeStartupAndRestoredSourcesWithoutPreview() {
        let app = XCUIApplication()
        // Runs the real C ABI startup/SQLite/bootstrap path; no UI fixtures.
        app.launchArguments = ["--ui-native-startup", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 35))
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertFalse(app.buttons["展开播放器"].exists)
        app.tabBars.buttons["我的"].tap()
        app.buttons["全部音乐来源"].tap()
        XCTAssertTrue(app.buttons["music-source-netease"].waitForExistence(timeout: 5))
        for _ in 0..<5 { if app.buttons["music-source-bilibili"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["music-source-bilibili"].exists)
        capture("real-native-startup-all-sources")
        app.terminate()
    }

    func testRealKeyboardSearchClearAndBackgroundReturn() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-native-startup", "--native-network-trace", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 35))
        app.tabBars.buttons["搜索"].tap()
        app.buttons["音源"].tap()
        // Public providers can be temporarily unavailable. Exercise the normal
        // aggregate flow here; the real single-source timeout remains recorded.
        app.buttons["选择全部来源"].tap()
        app.buttons["完成"].tap()
        let field = app.searchFields.firstMatch
        if !field.exists { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("周杰伦\n")
        let finished = app.buttons["search-song-0"]
        XCTAssertTrue(finished.waitForExistence(timeout: 30), "Real keyboard search did not show provider results")
        XCTAssertFalse(app.staticTexts["你想听见什么？"].exists)
        capture("search-real-keyboard-results")
        finished.tap()
        XCTAssertTrue(app.buttons["展开播放器"].waitForExistence(timeout: 10), "Real search result did not enter the existing player queue")
        capture("search-real-player-queue")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(finished.waitForExistence(timeout: 5))
        field.tap()
        if field.buttons.firstMatch.exists { field.buttons.firstMatch.tap() }
        else { field.press(forDuration: 1); app.menuItems["全选"].tap(); field.typeText(XCUIKeyboardKey.delete.rawValue) }
        XCTAssertTrue(app.staticTexts["你想听见什么？"].waitForExistence(timeout: 5))
        capture("search-real-cleared")
        app.terminate()
    }

    private func open(_ style: String, emptyPlayer: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-music.appearance", style]
        if emptyPlayer { app.launchArguments.append("--ui-empty-player") }
        app.launchArguments += extra
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
        XCTAssertTrue(app.buttons["展开播放器"].waitForExistence(timeout: 8))
        app.buttons["展开播放器"].tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        capture("05-player-light-fixture")
        app.buttons["歌词"].tap(); capture("06-lyrics-light-fixture")
        app.buttons["播放队列"].tap(); capture("07-queue-light-fixture")
    }
    func testNativeDarkAppearance() {
        let app = open("dark")
        capture("08-discover-dark-fixture")
        XCTAssertTrue(app.buttons["展开播放器"].waitForExistence(timeout: 8))
        app.buttons["展开播放器"].tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        capture("09-player-dark-fixture")
    }

    func testColdEmptyPlayerNavigationAndPlaybackLifecycle() {
        for style in ["light", "dark"] {
            let app = open(style, emptyPlayer: true)
            XCTAssertFalse(app.buttons["展开播放器"].exists)
            capture("empty-discover-\(style)")
            let tabFrame = app.tabBars.firstMatch.frame
            for tab in ["搜索", "音乐库", "我的", "发现"] {
                app.tabBars.buttons[tab].tap()
                XCTAssertFalse(app.buttons["展开播放器"].exists)
                XCTAssertEqual(app.tabBars.firstMatch.frame, tabFrame)
            }
            app.tabBars.buttons["音乐库"].tap()
            app.buttons["本地音乐"].tap()
            let song = app.buttons.containing(.staticText, identifier: "第一缕晨光").firstMatch
            XCTAssertTrue(song.waitForExistence(timeout: 8)); song.tap()
            XCTAssertTrue(app.buttons["展开播放器"].waitForExistence(timeout: 8))
            app.buttons["暂停"].tap()
            XCTAssertTrue(app.buttons["展开播放器"].exists)
            XCUIDevice.shared.press(.home); app.activate()
            XCTAssertTrue(app.buttons["展开播放器"].waitForExistence(timeout: 8))
            app.buttons["展开播放器"].tap()
            XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
            app.buttons["播放队列"].tap()
            app.buttons["清空"].tap()
            app.buttons["清空队列并停止播放"].tap()
            app.buttons["收起播放器"].tap()
            XCTAssertFalse(app.buttons["展开播放器"].exists)
            capture("cleared-player-\(style)")
            app.terminate()
        }
    }

    func testFinalLyricsUIHasOneCreditAndKeepsRepeatedChorus() {
        let app = open("light", extra: ["--ui-lyrics-duplicates"])
        app.buttons["展开播放器"].tap()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        app.buttons["歌词"].tap()
        XCTAssertTrue(app.buttons["作曲：周杰伦"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "作曲：周杰伦")).count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "编曲：林迈可")).count, 1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "重复副歌")).count, 2)
        capture("deduplicated-credits-preserved-chorus")
    }

    func testAllAccountsAndOfficialAuthorizationEntrypoints() {
        let app = open("light")
        app.tabBars.buttons["我的"].tap()
        let ids = ["netease", "apple", "qq", "soda", "kugou", "spotify"]
        app.buttons["全部音乐来源"].tap()
        for id in ids { XCTAssertTrue(app.buttons["music-source-" + id].exists) }
        for _ in 0..<5 { if app.buttons["music-source-bilibili"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.buttons["music-source-bilibili"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["我的"].tap()
        app.buttons["音源账号"].tap()
        for id in ids { XCTAssertTrue(app.buttons["account-source-" + id].exists) }

        app.buttons["account-source-apple"].tap()
        XCTAssertTrue(app.buttons["连接 Apple Music"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        app.navigationBars.buttons["音源账号"].tap()
        app.buttons["account-source-spotify"].tap()
        XCTAssertTrue(app.textFields["spotify-client-id"].exists)
        XCTAssertEqual(app.secureTextFields.count, 0)
        capture("official-accounts-spotify-pending")
    }
}
