import XCTest
@testable import TrinetSDK

final class AnnexBSplitterTests: XCTestCase {

    /// Three NALs (4-, 3- and 4-byte start codes) followed by the start of a
    /// fourth, which stays buffered until the next start code arrives.
    private let stream: [UInt8] =
        [0, 0, 0, 1, 0x67, 1, 2, 3] +           // SPS
        [0, 0, 1, 0x68, 4, 5] +                 // PPS
        [0, 0, 0, 1, 0x65, 6, 7, 8, 9] +        // IDR
        [0, 0, 0, 1, 0x41, 10]                  // P (incomplete tail)

    private let expected: [[UInt8]] = [[0x67, 1, 2, 3], [0x68, 4, 5], [0x65, 6, 7, 8, 9]]

    private func run(chunks: [Data]) -> [[UInt8]] {
        var s = AnnexBSplitter()
        var out: [[UInt8]] = []
        for c in chunks { s.push(c) { out.append(Array($0)) } }
        return out
    }

    func testWholeBuffer() {
        XCTAssertEqual(run(chunks: [Data(stream)]), expected)
    }

    func testEverySplitPoint() {
        // Start codes and NAL bodies split across every possible boundary.
        for cut in 1..<stream.count {
            let a = Data(stream[..<cut]), b = Data(stream[cut...])
            XCTAssertEqual(run(chunks: [a, b]), expected, "split at \(cut)")
        }
    }

    func testByteAtATime() {
        XCTAssertEqual(run(chunks: stream.map { Data([$0]) }), expected)
    }

    func testSliceWithNonZeroStartIndex() {
        // A Data slice keeps its parent's indices (startIndex != 0). The
        // splitter must not assume 0-based indices anywhere.
        let parent = Data([0xAA, 0xBB, 0xCC] + stream)
        let slice = parent[3...]
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(run(chunks: [slice]), expected)
    }
}
