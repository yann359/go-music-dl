import XCTest
@testable import MusicDL

final class LyricsTests: XCTestCase {
    func testMultipleTimestampsAndOffset() {
        let lines = LyricLine.parse("[offset:-500]\n[00:02.00][00:05.20]一句歌词\n[00:00.00]开始")
        XCTAssertEqual(lines.map(\.text), ["开始", "一句歌词", "一句歌词"])
        XCTAssertEqual(lines.compactMap(\.time), [0, 1.5, 4.7])
    }
    func testPlainTextDoesNotPretendToBeSynchronized() {
        let lines = LyricLine.parse("第一句\n第二句")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.time == nil })
    }
    func testMetadataAndInlineTimeAreRemoved() {
        let lines = LyricLine.parse("[ti:歌名]\n[00:01.00]<00:01.00>第一<00:01.50>句")
        XCTAssertEqual(lines.first?.text, "第一句")
        XCTAssertEqual(lines.count, 1)
    }
}
