import XCTest
@testable import Reel

final class CaptionTests: XCTestCase {

    func testGroupsRespectMaxWordsAndSpan() {
        let words = (0..<10).map { (text: "w\($0)", start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.3) }
        let lines = CaptionTrack.group(words: words, maxWords: 4, maxSpan: 2.2, gapBreak: 0.7)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertLessThanOrEqual(line.text.split(separator: " ").count, 4)
            XCTAssertLessThanOrEqual(line.end - line.start, 2.2 + 0.5)
        }
        // Every word survives, in order.
        XCTAssertEqual(lines.map(\.text).joined(separator: " "),
                       words.map(\.text).joined(separator: " "))
    }

    func testGapBreaksLine() {
        let words = [(text: "hello", start: 0.0, end: 0.4),
                     (text: "world", start: 3.0, end: 3.4)]   // 2.6 s gap ⇒ two lines
        let lines = CaptionTrack.group(words: words)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "hello")
        XCTAssertEqual(lines[1].text, "world")
    }

    func testLineLookup() {
        let track = CaptionTrack(lines: [CaptionLine(start: 1, end: 2, text: "a"),
                                         CaptionLine(start: 3, end: 4, text: "b")])
        XCTAssertEqual(track.line(at: 1.5), "a")
        XCTAssertEqual(track.line(at: 3.9), "b")
        XCTAssertNil(track.line(at: 2.5))
        XCTAssertNil(track.line(at: 0))
    }

    func testEmptyWordsProduceNoLines() {
        XCTAssertTrue(CaptionTrack.group(words: []).isEmpty)
    }
}
