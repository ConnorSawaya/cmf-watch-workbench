import Foundation
import WireKit

public enum TransferError: LocalizedError {
    case invalidPackage, invalidMap, mapUpdateRequired, refused(UInt8), noAcknowledgement
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: "The file is not a valid Watch Pro 2 app package."
        case .invalidMap: "Select a smaller map area, then try again."
        case .mapUpdateRequired: "Update the watch app loader to version 5 and Trail Map to version 11 before downloading this map."
        case .refused(let code): "The watch rejected the map (code \(code))."
        case .noAcknowledgement: "The watch did not confirm the map. Open Trail Map on the watch and try again."
        }
    }
}
private func u32(_ d: Data, _ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(d[p+$1]) << (8*$1) } }
private func u16(_ d: Data, _ p: Int) -> UInt16 { UInt16(d[p]) | UInt16(d[p+1]) << 8 }
private extension Data {
    mutating func le<T: FixedWidthInteger>(_ x: T) { Swift.withUnsafeBytes(of: x.littleEndian) { append(contentsOf: $0) } }
}
public struct ValidatedPackage: Sendable {
    public let data: Data
    public let header: PackageHeader
    public let imageBytes: Int
    public init(_ data: Data) throws {
        let d=Data(data)
        guard d.count>=64, d.count<=262208, d.prefix(4)==Data("WP2A".utf8),u16(d,4)==1,d[6]<=1,d[7]<=3,
              d[56..<64].allSatisfy({$0==0}),u32(d,52)==WireKit.crc32(Data(d.prefix(52))) else {throw TransferError.invalidPackage}
        let size=Int(u32(d,36)),count=Int(u32(d,44)),entry=Int(u32(d,40))
        guard size>0,size<=(d[6]==0 ? 131072:65536),entry<size,entry%2==0,count<=size/4,d.count==64+size+4*count,
              u32(d,48)==WireKit.crc32(Data(d.dropFirst(64))),let h=WireKit.parseHeader(d),!h.name.isEmpty,
              h.name.utf8.count<=23,h.name.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) else {throw TransferError.invalidPackage}
        var previous = -1
        for i in 0..<count {let off=Int(u32(d,64+size+4*i));guard off>previous,off<=size-4 else {throw TransferError.invalidPackage};previous=off}
        self.data=d;header=h;imageBytes=size
    }
}
public struct WatchSegment: Sendable {
    public var x1: Int16, y1: Int16, x2: Int16, y2: Int16
    public var kind: UInt8
    public init(x1: Int16,y1: Int16,x2: Int16,y2: Int16,kind: UInt8) {self.x1=x1;self.y1=y1;self.x2=x2;self.y2=y2;self.kind=kind}
}
public struct WatchSnapshot: Sendable {
    public let data: Data
    public init(x: Int32,y: Int32,metersPerPixel: UInt16,label: String,segments: [WatchSegment],screenCoordinates:Bool=false) throws {
        guard abs(Int64(x))<=21000000,abs(Int64(y))<=21000000,(1...60000).contains(metersPerPixel),segments.count<=400,(screenCoordinates || !segments.isEmpty),segments.allSatisfy({$0.kind<=4}) else {throw TransferError.invalidMap}
        var d=Data((screenCoordinates ? "TM02":"TM01").utf8);d.le(x);d.le(y);d.le(UInt16(segments.count));d.le(metersPerPixel)
        let title=Array(label.utf8.filter { (32...126).contains($0) }.prefix(31));d.append(contentsOf:title);d.append(Data(count:32-title.count))
        for s in segments {d.le(s.x1);d.le(s.y1);d.le(s.x2);d.le(s.y2);d.append(s.kind)}
        data=d
    }
    public init(data input:Data)throws {
        let data=Data(input)
        guard data.count>=48,data.count<=3648,[Data("TM01".utf8),Data("TM02".utf8)].contains(data.prefix(4)),abs(Int64(Int32(bitPattern:u32(data,4))))<=21000000,abs(Int64(Int32(bitPattern:u32(data,8))))<=21000000,(1...60000).contains(u16(data,14)) else{throw TransferError.invalidMap}
        let count=Int(u16(data,12));guard count<=400,data.count==48+count*9,data[16..<48].allSatisfy({$0==0 || (32...126).contains($0)}),(0..<count).allSatisfy({data[48+$0*9+8]<=4}) else{throw TransferError.invalidMap}
        self.data=Data(data)
    }
    public var centerX:Int32 {Int32(bitPattern:u32(data,4))}
    public var centerY:Int32 {Int32(bitPattern:u32(data,8))}
    public var scale:UInt16 {u16(data,14)}
    public var label:String {String(bytes:data[16..<48].prefix(while:{$0 != 0}),encoding:.ascii) ?? "Offline area"}
    public var segmentCount: Int {(data.count-48)/9}
    public func messages(id: UInt16) -> [Data] {
        var begin=Data([84,77,1,1]);begin.le(id);begin.le(UInt16(data.count));begin.le(WireKit.crc32(data))
        var out=[begin]
        for off in stride(from:0,to:data.count,by:120) {var m=Data([84,77,1,2]);m.le(id);m.le(UInt16(off));m.append(data[off..<min(off+120,data.count)]);out.append(m)}
        var end=Data([84,77,1,3]);end.le(id);out.append(end);return out
    }
}
public func mapAcknowledgement(_ d: Data,id: UInt16) -> UInt8? {
    guard d.count==7, d.prefix(4)==Data([84,77,1,128]),u16(d,4)==id else {return nil};return d[6]
}
public func sendSnapshot(_ snapshot: WatchSnapshot,over channel: any Channel,id: UInt16,progress: @Sendable (Double)->Void,received: @Sendable (Data) async ->Void = {_ in}) async throws {
    let messages=snapshot.messages(id:id)
    for (i,m) in messages.enumerated() {
        try Task.checkCancellation();try await channel.send(m)
        if i==0 || i==messages.count-1 {
            let until=ContinuousClock.now + .seconds(8)
            var confirmed=false
            while ContinuousClock.now<until {
                let d=try await channel.recv(timeout:until-ContinuousClock.now)
                if let status=mapAcknowledgement(d,id:id) {guard status==0 else {throw TransferError.refused(status)};confirmed=true;break}
                await received(d)
            }
            guard confirmed else {throw TransferError.noAcknowledgement}
        }
        progress(Double(i+1)/Double(messages.count))
    }
}
public func phoneFix(x: Int32,y: Int32,accuracy: UInt16) -> Data {
    guard abs(Int64(x))<=21000000,abs(Int64(y))<=21000000,(1...1000).contains(accuracy) else {return Data([84,77,1,5])}
    var d=Data([84,77,1,4]);d.le(x);d.le(y);d.le(accuracy);return d
}

/// Phone Core Location does not expose GNSS satellites. nil means unavailable, never zero.
public func phoneLocation(x:Int32,y:Int32,accuracy:UInt16,epoch:UInt32,age:UInt32,live:Bool,satellites:UInt8?=nil)->Data {
    guard abs(Int64(x))<=21000000,abs(Int64(y))<=21000000,(1...1000).contains(accuracy),satellites.map({$0<=100}) ?? true else{return Data([84,77,1,5])}
    var d=Data([84,77,1,6]);d.le(x);d.le(y);d.le(accuracy);d.append(live && age<10 ? 1:0);d.append(satellites ?? 255);d.le(epoch);d.le(age);return d
}
public enum WatchMapSyncPolicy {
    public static func shouldSend(changed:Bool,running:Bool,sinceSuccess:TimeInterval?,sinceAttempt:TimeInterval?)->Bool {
        changed && running && (sinceSuccess.map{$0>=10} ?? true) && (sinceAttempt.map{$0>=15} ?? true)
    }
}

public struct WatchViewport:Equatable,Sendable {
    public let x:Int32,y:Int32,scale:UInt16
    public init?(message input:Data) {
        let d=Data(input)
        guard d.count==14,d.prefix(4)==Data([84,77,1,0x11]) else{return nil}
        let x=Int32(bitPattern:u32(d,4)),y=Int32(bitPattern:u32(d,8)),scale=u16(d,12)
        guard abs(Int64(x))<=21000000,abs(Int64(y))<=21000000,(1...60000).contains(scale) else{return nil}
        self.x=x;self.y=y;self.scale=scale
    }
}
