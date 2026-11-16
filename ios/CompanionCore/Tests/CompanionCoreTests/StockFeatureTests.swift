import XCTest
@testable import CompanionCore

final class StockFeatureTests:XCTestCase {
    func testBatteryStatusUsesWatchLevelAndChargingFlag()throws {
        let value=try WatchBattery(data:Data([59,1]))
        XCTAssertEqual(value.percent,59);XCTAssertTrue(value.charging)
        XCTAssertThrowsError(try WatchBattery(data:Data([101,0])))
        XCTAssertThrowsError(try WatchBattery(data:Data([100])))
    }
    func testAlarmMatchesDocumentedWireExampleAndPreservesFlags()throws {
        let a=WatchAlarm(id:0,seconds:48600,enabled:true,weekdays:0x15,flag:0,label:"Wake")
        let d=try WatchAlarm.encode([a])
        XCTAssertEqual(Array(d.prefix(8)),[0,0,0xbd,0xd8,0,1,0x15,0])
        XCTAssertEqual(Array(d[8..<12]),Array("Wake".utf8))
        var readback=d;readback.replaceSubrange(0..<4,with:[0xd8,0xbd,0,0])
        XCTAssertEqual(try WatchAlarm.decode(readback),[a])
        XCTAssertThrowsError(try WatchAlarm.decode(Data(d.dropLast())))
        XCTAssertThrowsError(try WatchAlarm.encode([a,a]))
    }
    func testKnownGoalLayoutAndReminderRoundTrip()throws {
        let (a,c,d)=try WatchSetting.goals(steps:8000,meters:5000,kcal:400).packet()
        XCTAssertEqual(a,0x5e);XCTAssertEqual(c,1)
        XCTAssertEqual(Array(d),[0,0,0x1f,0x40,0,0,0x13,0x88,1,0x90])
        let reminder=WatchReminder(enabled:true,minutes:90,quietStart:79200,quietEnd:28800)
        XCTAssertEqual(try WatchReminder(data:reminder.encoded()),reminder)
        XCTAssertEqual(try WatchReminder(data:Data([0,0,60,0,0,0,0,0,0,0,0])).minutes,60)
        XCTAssertThrowsError(try WatchSetting.monitoring(kind:3,enabled:true).packet())
    }
    func testHealthRecordsUseCorrectUnitsAndDeduplicate() {
        var d=Data();for v in [UInt32(1700000000),200,150,4500,0,0,0,0] {d.writeLE(UInt64(v),4)}
        var h=WatchHealth();h.ingest(ability:0x56,command:1,data:d)
        XCTAssertEqual(h.activity.first?.calories,4500)
        var hr=Data();hr.writeLE(1700000000,4);hr.append(78)
        h.ingest(ability:0xda,command:1,data:hr)
        XCTAssertEqual(h.points.first?.value,78)
        let before=h;h.merge(before)
        XCTAssertEqual(h.activity.count,1);XCTAssertEqual(h.points.count,1)
        h.ingest(ability:0x56,command:1,data:Data(d.dropLast()))
        XCTAssertEqual(h.activity.count,1)
    }
    func testOutOfOrderChunksNeverFormRecord() {
        var chunks=StockChunks()
        let first=StockRawFrame(ability:0x63,command:1,count:2,index:1,body:Data())
        let last=StockRawFrame(ability:0x63,command:1,count:2,index:2,body:Data())
        XCTAssertNil(chunks.append(last,plain:Data([2])))
        XCTAssertNil(chunks.append(first,plain:Data([1])))
        XCTAssertEqual(chunks.append(last,plain:Data([2])),Data([1,2]))
    }
    func testContactLengthAndUnicodeValidation()throws {
        let good=[WatchContact(name:"Éva",number:"+15555550100")]
        let decoded=try WatchContact.decode(WatchContact.encode(good))
        XCTAssertEqual(decoded.first?.name,"Éva")
        XCTAssertThrowsError(try WatchContact.encode([WatchContact(name:String(repeating:"É",count:17),number:"1")]))
    }
}
