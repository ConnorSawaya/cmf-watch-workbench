import Foundation
import WireKit

public struct WatchOfflineMapInfo:Sendable {
    public let freeBytes:Int,bytes:Int,trailSegments:Int,stagedBytes:Int,crc:UInt32,version:UInt32
    public init?(message:Data) {
        guard message.count==28,Array(message.prefix(4))==[84,77,1,0x34] else{return nil}
        let b=Array(message);func word(_ p:Int)->UInt32 {(0..<4).reduce(0){$0|UInt32(b[p+$1])<<(8*$1)}}
        freeBytes=Int(word(4));bytes=Int(word(8));trailSegments=Int(word(12));stagedBytes=Int(word(16));crc=word(20);version=word(24)
    }
}
public enum OfflineMapTransferError:LocalizedError {
    case refused(Int32),invalidReply,tooLarge
    public var errorDescription:String? {
        switch self {case .refused(-28):return "There is not enough free watch storage. Existing installed maps are kept."
        case .refused(let code):return "The watch could not save the map (\(code)). Keep Trail Map open and retry to resume."
        case .invalidReply:return "The watch did not confirm the saved map."
        case .tooLarge:return "This map exceeds the watch's supported storage budget."}
    }
}
private func mapLE(_ n:UInt32)->Data {withUnsafeBytes(of:n.littleEndian){Data($0)}}
public func queryOfflineMap(over channel:any Channel,received:@Sendable(Data) async->Void={_ in}) async throws->WatchOfflineMapInfo {
    try await channel.send(Data([84,77,1,0x33]));let until=ContinuousClock.now + .seconds(12)
    while ContinuousClock.now<until {let d=try await channel.recv(timeout:until-ContinuousClock.now);if let info=WatchOfflineMapInfo(message:d){return info};await received(d)}
    throw OfflineMapTransferError.invalidReply
}
/// Resume at the watch-confirmed file offset. Each small batch is acknowledged;
/// the final file stays inactive until its complete CRC and header are checked.
@discardableResult public func sendOfflineMap(_ data:Data,version:UInt32,over channel:any Channel,progress:@Sendable(Int) async->Void={_ in},received:@Sendable(Data) async->Void={_ in}) async throws->WatchOfflineMapInfo {
    guard (64...9_200_000).contains(data.count),data.prefix(8)==Data("WP2MAP1\0".utf8) else{throw OfflineMapTransferError.tooLarge}
    let crc=WireKit.crc32(data)
    let info=try await queryOfflineMap(over:channel,received:received)
    if info.bytes==data.count && info.crc==crc && info.version==version {await progress(data.count);return info}
    func ack(_ op:UInt8) async throws->Int {
        let until=ContinuousClock.now + .seconds(30)
        while ContinuousClock.now<until {
            let d=try await channel.recv(timeout:until-ContinuousClock.now)
            if d.count==8,Array(d.prefix(4))==[84,77,1,op] {
                let b=Array(d);let value=(0..<4).reduce(UInt32(0)){$0|UInt32(b[4+$1])<<(8*$1)};let signed=Int32(bitPattern:value)
                guard signed>=0 else{throw OfflineMapTransferError.refused(signed)};return Int(signed)
            }
            await received(d)
        }
        throw OfflineMapTransferError.invalidReply
    }
    try await channel.send(Data([84,77,1,0x30])+mapLE(UInt32(data.count))+mapLE(crc)+mapLE(version))
    var offset=try await ack(0xb0);guard offset<=data.count else{throw OfflineMapTransferError.invalidReply};await progress(offset)
    while offset<data.count {
        let end=min(offset+116*16,data.count)
        while offset<end {
            try Task.checkCancellation();let next=min(offset+116,end)
            try await channel.send(Data([84,77,1,0x31])+mapLE(UInt32(offset))+Data([next==end ? 1:0])+data[offset..<next]);offset=next
        }
        guard try await ack(0xb1)==offset else{throw OfflineMapTransferError.invalidReply};await progress(offset)
    }
    try await channel.send(Data([84,77,1,0x32]));guard try await ack(0xb2)==0 else{throw OfflineMapTransferError.invalidReply}
    let complete=try await queryOfflineMap(over:channel,received:received)
    guard complete.bytes==data.count,complete.crc==crc,complete.version==version else{throw OfflineMapTransferError.invalidReply};return complete
}
