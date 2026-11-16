import XCTest
@testable import CompanionCore
final class MapFileTests:XCTestCase {
    func testRealConverterOutputAndCorruptReplacement() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url=root.appendingPathComponent("build/demo/demo-map.wp2map")
        guard FileManager.default.fileExists(atPath:url.path) else{throw XCTSkip("Run tools/build_demo.sh first")}
        let data=try Data(contentsOf:url)
        let map=try WatchMapFile(data)
        XCTAssertEqual(map.data,data)
        XCTAssertThrowsError(try WatchMapFile(Data(data.dropLast())))
        var bad=data;bad[bad.count-2] ^= 1
        XCTAssertThrowsError(try WatchMapFile(bad))
        bad=data;bad[60] ^= 1
        XCTAssertThrowsError(try WatchMapFile(bad))
    }
}
