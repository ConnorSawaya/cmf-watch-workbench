import XCTest
import WireKit
@testable import CompanionCore
private actor MapChannel:Channel {
    var bytes:Data,expected=0,wanted:UInt32=0,version:UInt32=0,inbox=[Data](),committed=false,chunks=0,begins=0
    let corrupt:Bool
    init(prefix:Data=Data(),complete:Bool=false,corrupt:Bool=false) {bytes=prefix;committed=complete;self.corrupt=corrupt;if complete{expected=prefix.count;wanted=WireKit.crc32(prefix);version=1}}
    func word(_ d:Data,_ p:Int)->UInt32 {(0..<4).reduce(0){$0|UInt32(d[p+$1])<<(8*$1)}}
    func le(_ n:UInt32)->Data {withUnsafeBytes(of:n.littleEndian){Data($0)}}
    func ack(_ op:UInt8,_ n:Int32) {inbox.append(Data([84,77,1,op])+le(UInt32(bitPattern:n)))}
    func send(_ d:Data) async throws {
        switch d[3] {
        case 0x33:inbox.append(Data([84,77,1,0x34])+le(10_000_000)+le(committed ? UInt32(bytes.count):0)+le(12)+le(UInt32(bytes.count))+le(committed ? wanted:0)+le(committed ? version:0))
        case 0x30:begins+=1;expected=Int(word(d,4));wanted=word(d,8);version=word(d,12);ack(0xb0,Int32(bytes.count))
        case 0x31:
            guard Int(word(d,4))==bytes.count,d.count<=128 else{throw OfflineMapTransferError.invalidReply};chunks+=1;bytes.append(d.dropFirst(9));if d[8]==1{ack(0xb1,Int32(bytes.count))}
        case 0x32:
            if corrupt{bytes[bytes.count-1]^=1};committed=bytes.count==expected && WireKit.crc32(bytes)==wanted;ack(0xb2,committed ? 0:-5)
        default:throw OfflineMapTransferError.invalidReply
        }
    }
    func recv(timeout:Duration) async throws->Data {guard !inbox.isEmpty else{throw WireError.timeout("test inbox")};return inbox.removeFirst()}
    func result()->(Bool,Int,Int,Data) {(committed,begins,chunks,bytes)}
}
final class WatchOfflineMapTests:XCTestCase {
    func fixture()->Data {Data("WP2MAP1\0".utf8)+Data((0..<6000).map{UInt8($0%251)})}
    func testInterruptedFileResumesAtConfirmedOffset() async throws {
        let data=fixture(),channel=MapChannel(prefix:Data(fixture().prefix(1600)))
        let info=try await sendOfflineMap(data,version:1,over:channel)
        XCTAssertEqual(info.bytes,data.count);XCTAssertEqual(info.crc,WireKit.crc32(data))
        let result=await channel.result();XCTAssertTrue(result.0);XCTAssertEqual(result.3,data);XCTAssertLessThan(result.2,50)
    }
    func testUnchangedInstalledMapDoesNotDownloadAgain() async throws {
        let data=fixture(),channel=MapChannel(prefix:fixture(),complete:true)
        _=try await sendOfflineMap(data,version:1,over:channel)
        let result=await channel.result();XCTAssertEqual(result.1,0);XCTAssertEqual(result.2,0)
    }
    func testFailedChecksumIsNotReportedInstalled() async throws {
        let channel=MapChannel(corrupt:true)
        do{_ = try await sendOfflineMap(fixture(),version:1,over:channel);XCTFail("Corrupt file accepted")}catch OfflineMapTransferError.refused(-5){}catch{XCTFail("Unexpected error: \(error)")}
        let result=await channel.result();XCTAssertFalse(result.0)
    }
    func testRejectsMalformedStatus() {XCTAssertNil(WatchOfflineMapInfo(message:Data([84,77,1,0x34])))}
}
