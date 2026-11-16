import Foundation
import WireKit
public struct WatchPlace:Sendable{public let x:Int32,y:Int32,name:String;public init(x:Int32,y:Int32,name:String){self.x=x;self.y=y;self.name=name}}
public func watchPlacesData(_ places:[WatchPlace])throws->Data{
    func le<T:FixedWidthInteger>(_ x:T)->Data{withUnsafeBytes(of:x.littleEndian){Data($0)}}
    guard places.count<=32,places.allSatisfy({abs(Int64($0.x))<=21_000_000 && abs(Int64($0.y))<=21_000_000}) else{throw TransferError.invalidMap}
    var records=Data()
    for p in places{records+=le(p.x);records+=le(p.y);let bytes=Array(p.name.decomposedStringWithCanonicalMapping.utf8.filter{(32...126).contains($0)}.prefix(24));records+=Data(bytes);records+=Data(repeating:0,count:24-bytes.count)}
    return Data("TP10".utf8)+le(UInt16(places.count))+le(UInt16(0))+le(WireKit.crc32(records))+records
}
public func syncWatchPlaces(_ places:[WatchPlace],over channel:any Channel,received:@Sendable(Data) async->Void={_ in})async throws->Int{
    let payload=try watchPlacesData(places);let crc=payload.subdata(in:8..<12)
    func notice()async throws->Data{
        try await channel.send(Data([84,77,1,0x43]));let end=ContinuousClock.now + .seconds(8)
        while ContinuousClock.now<end{let d=try await channel.recv(timeout:end-ContinuousClock.now);if d.count==10,d.prefix(4)==Data([84,77,1,0x44]),d[4]<=32{return d};await received(d)}
        throw TransferError.noAcknowledgement
    }
    let existing=try await notice();if existing[4]==places.count,existing.subdata(in:6..<10)==crc{return places.count}
    func ack(_ op:UInt8)async throws->Int{
        let end=ContinuousClock.now + .seconds(8)
        while ContinuousClock.now<end{let d=try await channel.recv(timeout:end-ContinuousClock.now);if d.count==8,d.prefix(4)==Data([84,77,1,op]){let n=(0..<4).reduce(UInt32(0)){$0|UInt32(d[4+$1])<<(8*$1)};let v=Int32(bitPattern:n);guard v>=0 else{throw OfflineMapTransferError.refused(v)};return Int(v)};await received(d)};throw TransferError.noAcknowledgement
    }
    try await channel.send(Data([84,77,1,0x40,UInt8(payload.count&255),UInt8(payload.count>>8)]));guard try await ack(0xc0)==0 else{throw TransferError.invalidMap}
    for offset in stride(from:0,to:payload.count,by:120){let end=min(offset+120,payload.count);try await channel.send(Data([84,77,1,0x41,UInt8(offset&255),UInt8(offset>>8)])+payload[offset..<end]);guard try await ack(0xc1)==end else{throw TransferError.noAcknowledgement}}
    try await channel.send(Data([84,77,1,0x42]));guard try await ack(0xc2)==0 else{throw TransferError.noAcknowledgement};let saved=try await notice();guard saved[4]==places.count,saved.subdata(in:6..<10)==crc else{throw TransferError.noAcknowledgement};return places.count
}
