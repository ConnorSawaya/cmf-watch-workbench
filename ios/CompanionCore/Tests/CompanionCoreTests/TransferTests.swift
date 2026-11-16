import XCTest
import WireKit
@testable import CompanionCore
final class TransferTests:XCTestCase {
    func testActualPackagesAndCorruption() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["stopwatch","loader"] {
            let url=root.appendingPathComponent("firmware/wp2-apps/target/\(name).wp2app")
            guard FileManager.default.fileExists(atPath:url.path) else{throw XCTSkip("Build the watch packages first")}
            let d=try Data(contentsOf:url);let p=try ValidatedPackage(d);XCTAssertEqual(p.header.name,name)
            var broken=d;broken[broken.count-1] ^= 1;XCTAssertThrowsError(try ValidatedPackage(broken))
            XCTAssertThrowsError(try ValidatedPackage(Data(d.dropLast())))
        }
    }
}
