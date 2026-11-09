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

    func testLibraryVerbatimWordBoundariesNeverDuplicateWholeLines() {
        // Exact square-bracket format emitted by music-lib ConvertVerbatimLRC.
        let lines = LyricLine.parse("[00:01.00]作[00:01.20]曲：周杰伦[00:02.00]\n[00:03.00]编曲：林迈可[00:04.00]\n[00:05.00]你[00:05.50]好[00:06.00]")
        XCTAssertEqual(lines.map(\.text), ["作曲：周杰伦", "编曲：林迈可", "你好"])
        XCTAssertEqual(lines.compactMap(\.time), [1, 3, 5])
    }

    func testCreditBlockDeduplicatesOnlyMatchingRolesAndPeople() {
        let lines = LyricLine.parse("[00:01.00]作曲: 周杰伦\n[00:02.00]编曲：林迈可\n[00:03.00]作曲：周杰伦\n[00:04.00]編曲 : 林迈可\n[00:05.00]作曲：另一位\n[00:06.00]第一句\n[00:07.00]第一句\n[00:08.00]作曲：周杰伦")
        XCTAssertEqual(lines.map(\.text), ["作曲：周杰伦", "编曲：林迈可", "作曲：另一位", "第一句", "第一句", "作曲：周杰伦"])
        XCTAssertEqual(lines.compactMap(\.time), [1, 2, 5, 6, 7, 8])
        XCTAssertEqual(lines.map(\.id), Array(0..<6))
    }

    func testChorusRepeatedTimestampsAndSameTimeHarmoniesStayIntact() {
        let lines = LyricLine.parse("[00:01.00][00:11.00]副歌\n[00:01.00]和声\n[00:12.00]副歌")
        XCTAssertEqual(lines.map(\.text), ["副歌", "和声", "副歌", "副歌"])
        XCTAssertEqual(lines.compactMap(\.time), [1, 1, 11, 12])
    }

    func testPlainCreditNormalizationDoesNotRemoveRepeatedWords() {
        let lines = LyricLine.parse("作詞 : 方文山\n作词： 方文山\n想你\n想你")
        XCTAssertEqual(lines.map(\.text), ["作词：方文山", "想你", "想你"])
    }
}
