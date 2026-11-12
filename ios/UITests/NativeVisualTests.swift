import XCTest

final class NativeVisualTests: XCTestCase {
    func testRealPlaylistTextImportAndRelaunchPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-native-startup", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 35))
        app.tabBars.buttons["音乐库"].tap()
        app.buttons["创建歌单"].tap()
        let name = "Import UI " + String(UUID().uuidString.prefix(6))
        let field = app.alerts["新建歌单"].textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(name)
        app.alerts["新建歌单"].buttons["创建"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10)); app.staticTexts[name].tap()
        XCTAssertTrue(app.buttons["playlist-add-songs"].waitForExistence(timeout: 8))
        app.buttons["playlist-add-songs"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("周杰伦 晴天")
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "song-selection-row-"))
        XCTAssertTrue(options.element(boundBy: 1).waitForExistence(timeout: 45), "Real providers must return two selectable songs")
        // Bind to real source identities before asynchronous sources finish.
        let first = app.buttons[options.element(boundBy: 0).identifier]
        let second = app.buttons[options.element(boundBy: 1).identifier]
        first.tap()
        let firstSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [firstSelected], timeout: 5), .completed)
        // Bring a partly clipped row fully above the native bottom search field.
        if second.frame.maxY >= search.frame.minY {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: search.frame.minY - 20))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 180))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        second.tap()
        let secondSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: second)
        XCTAssertEqual(XCTWaiter.wait(for: [secondSelected], timeout: 5), .completed)
        let done = app.buttons["song-selection-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertTrue(done.isHittable, "Commit must remain reachable with the search keyboard visible")
        XCTAssertTrue(done.label.contains("2")); done.tap()
        XCTAssertTrue(app.buttons["playlist-import"].waitForExistence(timeout: 25))
        capture("playlist-native-real-search-multiple-added")
        app.buttons["playlist-import"].tap()
        app.buttons["粘贴歌曲列表"].tap()
        let editor = app.textViews["playlist-import-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap()
        editor.typeText("MusicDL Test Artist - Import Verification Track")
        app.buttons["读取并预览"].tap()
        XCTAssertTrue(app.buttons["playlist-import-confirm"].waitForExistence(timeout: 10))
        capture("playlist-import-native-preview")
        app.buttons["playlist-import-confirm"].tap()
        app.buttons["确认导入"].tap()
        XCTAssertTrue(app.navigationBars["导入结果"].waitForExistence(timeout: 10))
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "导入完成"), object: app.staticTexts["playlist-import-phase"])
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed, "Wait for the actual SQLite commit before terminating the app")
        capture("playlist-import-native-result")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 35)); app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 8)); app.staticTexts[name].tap()
        for _ in 0..<3 { if app.staticTexts["Import Verification Track"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Import Verification Track"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "暂不可播放")).firstMatch.exists)
        capture("playlist-import-native-persisted")
        app.terminate()
    }

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
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        app.buttons["收起播放器"].tap()
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
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-music.appearance", style, "-music.themeColor", "appleRed"]
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

    func testColdEmptyPlayerNavigationAndPlaybackLifecycleLight() {
        verifyColdEmptyPlayerLifecycle(style: "light")
    }

    func testColdEmptyPlayerNavigationAndPlaybackLifecycleDark() {
        verifyColdEmptyPlayerLifecycle(style: "dark")
    }

    private func verifyColdEmptyPlayerLifecycle(style: String) {
        let app = open(style, emptyPlayer: true)
        defer { app.terminate() }
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
        guard tapVisibleAccessory(app, id: "mini-player-play-pause") else { return }
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已暂停"), object: app.buttons["mini-player-play-pause"])
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["展开播放器"].exists)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(app.buttons["展开播放器"].waitForExistence(timeout: 8))
        capture("accessory-before-reopen-\(style)")
        guard tapVisibleAccessory(app, id: "open-player") else { return }
        // An actual expanded view, rather than a successful tap call, proves navigation.
        guard app.buttons["收起播放器"].waitForExistence(timeout: 8) else {
            XCTFail("Visible accessory touch did not open the player")
            return
        }
        app.buttons["播放队列"].tap()
        app.buttons["清空"].tap()
        app.buttons["清空队列并停止播放"].tap()
        app.buttons["收起播放器"].tap()
        XCTAssertFalse(app.buttons["展开播放器"].exists)
        capture("cleared-player-\(style)")
    }

    /// iOS 26's zoom/bottom accessory can publish a stale AX activation point.
    /// Touch the current visible frame, then assert the actual UI/state outcome.
    /// If the button's frame is invalid, use its observed accessory ancestor and
    /// MiniPlayer's unchanged 12pt padding / 12pt gaps / 44pt and 40pt controls.
    private func tapVisibleAccessory(_ app: XCUIApplication, id: String) -> Bool {
        let button = app.buttons[id]
        guard button.waitForExistence(timeout: 8) else { XCTFail("Missing accessory control: \(id)"); return false }
        let window = app.frame
        func visible(_ rect: CGRect) -> Bool {
            rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite &&
                rect.width > 0 && rect.height > 0 && window.insetBy(dx: -1, dy: -1).contains(rect)
        }
        let frame = button.frame
        let point: CGPoint
        if visible(frame) {
            point = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            let ancestors = app.otherElements.containing(.button, identifier: "open-player").allElementsBoundByIndex
                .map(\.frame).filter { visible($0) && $0.width > window.width * 0.6 && (40...80).contains($0.height) && $0.minY > window.height * 0.6 }
            guard let accessory = ancestors.min(by: { $0.height < $1.height }) else {
                XCTFail("No observed visible accessory frame for \(id)")
                return false
            }
            if id == "open-player" {
                let openingWidth = accessory.width - 24 - 44 - 40 - 24
                point = CGPoint(x: accessory.minX + 12 + openingWidth / 2, y: accessory.midY)
            } else {
                point = CGPoint(x: accessory.maxX - 12 - 40 - 12 - 22, y: accessory.midY)
            }
        }
        guard window.contains(point) else { XCTFail("Accessory touch point outside app"); return false }
        print("[ui-accessory-touch] id=\(id) frame=\(frame) point=\(point)")
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - window.minX, dy: point.y - window.minY)).tap()
        return true
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

    func testSystemMediaIslandTapWhenExposedBySimulator() throws {
        let app = open("light", emptyPlayer: true)
        defer { app.terminate() }
        app.tabBars.buttons["音乐库"].tap()
        app.buttons["本地音乐"].tap()
        let song = app.buttons.containing(.staticText, identifier: "第一缕晨光").firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 8)); song.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 8))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在播放"), object: app.buttons["暂停"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 8), .completed)
        // Preserve both states for comparison even if system accessibility is
        // unavailable. A passing in-app playback test cannot prove the visual
        // foreground-to-Home handoff requested by the user.
        capture("system-media-playing-inside-app-before-home")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Use a real system accessibility target. Never equate app.activate()
        // or a guessed coordinate with a successful Dynamic Island tap.
        // Match track content, not the app name: a Home Screen app icon is
        // not evidence of a system media-island interaction.
        let media = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "第一缕晨光")).firstMatch
        let exposed = media.waitForExistence(timeout: 8)
        let systemShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        systemShot.name = "system-media-home-probe"; systemShot.lifetime = .keepAlways; add(systemShot)
        guard exposed else {
            throw XCTSkip("Simulator does not expose an identifiable system media island; iPhone tap/long-press remains unverified.")
        }
        media.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8), "System media tap did not activate MusicDL")
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        capture("system-media-tap-restored-player")
    }

    func testSystemMediaIslandLongPressControlsWhenExposedBySimulator() throws {
        let app = open("light", emptyPlayer: true)
        defer { app.terminate() }
        app.tabBars.buttons["音乐库"].tap()
        app.buttons["本地音乐"].tap()
        let song = app.buttons.containing(.staticText, identifier: "第一缕晨光").firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 8)); song.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 8))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在播放"), object: app.buttons["暂停"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 8), .completed)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let media = springboard.buttons.matching(NSPredicate(format: "label CONTAINS %@", "第一缕晨光")).firstMatch
        guard media.waitForExistence(timeout: 8) else {
            throw XCTSkip("Simulator does not expose the track's media island; long-press requires iPhone verification.")
        }
        media.press(forDuration: 1)
        let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        expanded.name = "system-media-long-press-probe"; expanded.lifetime = .keepAlways; add(expanded)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "Long-press should expand system controls without opening the app")
        let pause = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["暂停", "Pause"])).firstMatch
        guard pause.waitForExistence(timeout: 5) else {
            throw XCTSkip("Expanded system controls are not accessible in this simulator; pause/resume remains unverified.")
        }
        pause.tap()
        let play = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["播放", "Play"])).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        // app.activate is only for verifying the resulting app state here;
        // the separate tap test is the evidence for system-to-app activation.
        app.activate()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
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

    func testThemeColorsAcrossLightDarkAndSystemModes() {
        let app = open("light")
        defer { app.terminate() }
        app.tabBars.buttons["我的"].tap()
        app.buttons["appearance-settings"].tap()
        let colors = ["appleRed", "oceanBlue", "mintGreen", "dreamPurple", "sunsetOrange", "cherryPink", "auroraCyan", "graphiteGray"]
        for mode in ["light", "dark", "system"] {
            app.swipeDown(); app.swipeDown()
            let option = app.buttons["appearance-" + mode]
            XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
            XCTAssertEqual(option.value as? String, "已选中")
            for color in colors {
                let card = app.buttons["theme-" + color]
                for _ in 0..<3 { if card.isHittable { break }; app.swipeUp() }
                XCTAssertTrue(card.isHittable, "Theme card inaccessible: \(color) / \(mode)")
                card.tap()
                XCTAssertEqual(card.value as? String, "已选中")
                // Accessibility's transformed CGRect can return 43.9999847
                // for a 44pt circle. Tolerate < 1/300 of a physical pixel.
                XCTAssertGreaterThanOrEqual(card.frame.width, 44 - 0.001)
                XCTAssertGreaterThanOrEqual(card.frame.height, 44 - 0.001)
                XCTAssertLessThanOrEqual(card.frame.maxX, app.frame.maxX)
            }
            capture("appearance-eight-colors-" + mode)
        }
    }

    func testAppearancePersistsAfterRelaunchAndResetOnlyChangesAppearance() {
        let app = open("light")
        defer { app.terminate() }
        app.tabBars.buttons["我的"].tap(); app.buttons["appearance-settings"].tap()
        app.buttons["appearance-dark"].tap()
        app.buttons["theme-oceanBlue"].tap()
        app.terminate()
        // Remove command-line defaults: verify the values written to storage.
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        app.tabBars.buttons["我的"].tap(); app.buttons["appearance-settings"].tap()
        XCTAssertEqual(app.buttons["appearance-dark"].value as? String, "已选中")
        XCTAssertEqual(app.buttons["theme-oceanBlue"].value as? String, "已选中")
        capture("appearance-oceanBlue-persisted-dark")
        for _ in 0..<3 { if app.buttons["theme-restore"].isHittable { break }; app.swipeUp() }
        app.buttons["theme-restore"].tap()
        app.buttons["恢复外观默认值"].tap()
        app.swipeDown(); app.swipeDown()
        XCTAssertEqual(app.buttons["appearance-system"].value as? String, "已选中")
        XCTAssertEqual(app.buttons["theme-appleRed"].value as? String, "已选中")
        app.tabBars.buttons["音乐库"].tap()
        XCTAssertTrue(app.buttons["本地音乐"].waitForExistence(timeout: 5))
        app.buttons["本地音乐"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "第一缕晨光").firstMatch.waitForExistence(timeout: 5))
        capture("appearance-restored-library-preserved")
    }

    func testMediaRepairRunsAndKeepsPlayingThenPausedState() {
        let app = open("light", emptyPlayer: true)
        defer { app.terminate() }
        app.tabBars.buttons["音乐库"].tap(); app.buttons["本地音乐"].tap()
        let song = app.buttons.containing(.staticText, identifier: "第一缕晨光").firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 8)); song.tap()
        let pause = app.buttons["mini-player-play-pause"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在播放"), object: pause)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 8), .completed)
        app.tabBars.buttons["我的"].tap()
        app.buttons["media-repair-settings"].tap()
        app.buttons["media-repair-start"].tap()
        XCTAssertTrue(app.staticTexts["media-repair-summary"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["检测未完成，请重新检测"].exists)
        XCTAssertEqual(pause.value as? String, "正在播放")
        capture("media-repair-playing-result")
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 8))
        // Use the actual visible transport. This simulator can expose an
        // invalid AX activation point for the bottom accessory after zoom
        // dismissal; that does not prove a device touch succeeded or failed.
        let returnedControl = app.buttons["full-player-play-pause"]
        XCTAssertTrue(returnedControl.waitForExistence(timeout: 8))
        let stillPlaying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在播放"), object: returnedControl)
        XCTAssertEqual(XCTWaiter.wait(for: [stillPlaying], timeout: 8), .completed)
        capture("media-repair-home-return-still-playing")
        returnedControl.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已暂停"), object: returnedControl)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        app.buttons["收起播放器"].tap()
        XCTAssertTrue(app.staticTexts["media-repair-summary"].waitForExistence(timeout: 5))
        app.buttons["media-repair-start"].tap()
        XCTAssertTrue(app.staticTexts["media-repair-summary"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["检测未完成，请重新检测"].exists)
        capture("media-repair-paused-result")
    }
}
