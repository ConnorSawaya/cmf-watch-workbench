import XCTest
@testable import CompanionCore
final class MapFileTests:XCTestCase {
    func testRealConverterOutputAndCorruptReplacement() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url=root.appendingPathComponent("build/demo/demo-map.wp2map")
        guard FileManager.default.fileExists(atPath:url.path) else{throw XCTSkip("Run tools/build_demo.sh first")}
        let data=try Data(contentsOf:url)
        let map=try WatchMapFile(data)
        XCTAssertEqual(map.codec,2)
        XCTAssertEqual(map.data,data)
        XCTAssertThrowsError(try WatchMapFile(Data(data.dropLast())))
        var bad=data;bad[bad.count-2] ^= 1
        XCTAssertThrowsError(try WatchMapFile(bad))
        // A spatial page cannot claim coordinates outside its 8 km cell.
        func word(_ p:Int)->Int {(0..<4).reduce(0){$0|Int(data[p+$1])<<(8*$1)}}
        let cells=(word(28)-64)/8
        let offset=(0..<cells).map{word(64+$0*8)}.first{$0 != 0}!
        bad=data;bad[offset+12]=255;bad[offset+13]=255
        XCTAssertThrowsError(try WatchMapFile(bad))
        bad=data;bad[60] ^= 1
        XCTAssertThrowsError(try WatchMapFile(bad))
    }
}
