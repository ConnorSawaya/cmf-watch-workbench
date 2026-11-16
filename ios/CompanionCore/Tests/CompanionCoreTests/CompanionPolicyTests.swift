import XCTest
import CryptoKit
@testable import CompanionCore

final class CompanionPolicyTests:XCTestCase {
    func testUnsafeInstallConditionsRefuse() throws {
        XCTAssertNoThrow(try CompanionPolicy.validateInstall(firmware:"1.0.0.73",battery:70,batteryAge:2,runningSlot:255))
        for fw in [nil,"1.0.0.74"] {XCTAssertThrowsError(try CompanionPolicy.validateInstall(firmware:fw,battery:70,batteryAge:2,runningSlot:255))}
        for battery in [nil,0,29] {XCTAssertThrowsError(try CompanionPolicy.validateInstall(firmware:"1.0.0.73",battery:battery,batteryAge:2,runningSlot:255))}
        for age in [nil,-1,120,500] as [TimeInterval?] {XCTAssertThrowsError(try CompanionPolicy.validateInstall(firmware:"1.0.0.73",battery:70,batteryAge:age,runningSlot:255))}
        XCTAssertThrowsError(try CompanionPolicy.validateInstall(firmware:"1.0.0.73",battery:70,batteryAge:2,runningSlot:0))
    }
    func testAutoSyncThrottleAndActiveAppGuards() {
        let now=Date(timeIntervalSince1970:1_800_000_000)
        func due(sync:TimeInterval?=nil,attempt:TimeInterval?=nil,foreground:Bool=true,enabled:Bool=true,busy:Bool=false,gps:Bool=false)->Bool {
            CompanionPolicy.syncDue(now:now,lastSync:sync.map{now.addingTimeInterval(-$0)},lastAttempt:attempt.map{now.addingTimeInterval(-$0)},foreground:foreground,enabled:enabled,busy:busy,sharingGPS:gps)
        }
        XCTAssertTrue(due());XCTAssertTrue(due(sync:900,attempt:300))
        XCTAssertTrue(CompanionPolicy.syncDue(now:now,lastSync:now.addingTimeInterval(-61),lastAttempt:nil,foreground:true,enabled:true,busy:false,sharingGPS:false,minimumInterval:60))
        XCTAssertFalse(CompanionPolicy.syncDue(now:now,lastSync:now.addingTimeInterval(-59),lastAttempt:nil,foreground:true,enabled:true,busy:false,sharingGPS:false,minimumInterval:60))
        XCTAssertFalse(due(sync:899));XCTAssertFalse(due(attempt:299));XCTAssertFalse(due(sync:-100))
        XCTAssertFalse(due(foreground:false));XCTAssertFalse(due(enabled:false));XCTAssertFalse(due(busy:true));XCTAssertFalse(due(gps:true))
    }
    func testLargeBackwardTimeAndTimezoneCorrectionsBlocked() {
        XCTAssertNoThrow(try CompanionPolicy.validateClock(epoch:10000,offset:0,lastEpoch:nil,lastOffset:nil,elapsed:0))
        XCTAssertNoThrow(try CompanionPolicy.validateClock(epoch:10060,offset:0,lastEpoch:10000,lastOffset:0,elapsed:60))
        XCTAssertThrowsError(try CompanionPolicy.validateClock(epoch:10000,offset:0,lastEpoch:10000,lastOffset:0,elapsed:121))
        XCTAssertThrowsError(try CompanionPolicy.validateClock(epoch:10060,offset:-3600,lastEpoch:10000,lastOffset:0,elapsed:60))
    }
    func testOnlyExactTestedBuildAccepted() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder=root.appendingPathComponent("ios/TrailCompanion/Resources")
        let records=try JSONDecoder().decode([TestedPackage].self,from:Data(contentsOf:folder.appendingPathComponent("tested-packages.json")))
        if records.isEmpty {throw XCTSkip("Run tools/build_apps.sh and the package staging check first")}
        XCTAssertTrue(Set(records.map(\.name)).isSuperset(of:["loader","trail-map"]))
        for record in records {
            let package=try ValidatedPackage(Data(contentsOf:folder.appendingPathComponent(record.name+".wp2app")))
            XCTAssertNoThrow(try record.verify(package))
            let wrong=TestedPackage(name:record.name,kind:record.kind,version:record.version,bytes:record.bytes,sha256:String(repeating:"0",count:64))
            XCTAssertThrowsError(try wrong.verify(package))
            let other=TestedPackage(name:"other",kind:record.kind,version:record.version,bytes:record.bytes,sha256:record.sha256)
            XCTAssertThrowsError(try other.verify(package))
        }
    }
}
