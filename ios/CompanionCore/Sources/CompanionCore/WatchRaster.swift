import Foundation
import WireKit

/// Native display sized indexed artwork. Long runs use a one-byte extension.
public struct WatchRaster:Sendable {
    public static let width=450,height=257,capacity=32736
    public static let palette:[UInt16]=[
        0xCEFE,0xF75B,0xC6F7,0xB675,0x9E3B,0xFFFF,0xB5B5,0x3409,
        0x335B,0x1924,0x8C91,0xF7BD,0xDEB9,0xEA63,0x73CE,0xBDD5
    ]
    public let x:Int32,y:Int32,scale:UInt16,data:Data
    public init(x:Int32,y:Int32,scale:UInt16,pixels:[UInt8])throws {
        guard abs(Int64(x))<=21000000,abs(Int64(y))<=21000000,(1...60000).contains(scale),pixels.count==Self.width*Self.height,pixels.allSatisfy({$0<15}) else{throw TransferError.invalidMap}
        var bytes=Data([0]);var i=0
        func run(_ start:Int)->Int {let color=pixels[start];var end=start+1;while end<pixels.count && end-start<271 && pixels[end]==color {end+=1};return end-start}
        func appendRun(_ start:Int,_ count:Int) {let color=pixels[start];if count>=16 {bytes.append(color<<4|15);bytes.append(UInt8(count-16))}else{bytes.append(color<<4|UInt8(count-1))}}
        while i<pixels.count {
            let count=run(i)
            if count>=3 {appendRun(i,count);i+=count;continue}
            var end=i
            while end<min(i+32,pixels.count) {
                if end>i && run(end)>=3 {break}
                end+=1
            }
            end-=(end-i)%2
            if end-i<2 {appendRun(i,count);i+=count;continue}
            bytes.append(0xF0|UInt8((end-i)/2-1))
            for j in stride(from:i,to:end,by:2) {bytes.append(pixels[j]<<4|pixels[j+1])}
            i=end
        }
        if bytes.count>Self.capacity {
            // Dense views retain every pixel with four chosen display colors.
            // White roads and dark labels always stay distinct.
            var histogram=[Int](repeating:0,count:15);for p in pixels {histogram[Int(p)]+=1}
            let rgb=Self.palette.map{(Int(($0>>11)&31)*8,Int(($0>>5)&63)*4,Int($0&31)*8)}
            func distance(_ a:Int,_ b:Int)->Int {let a=rgb[a],b=rgb[b];return (a.0-b.0)*(a.0-b.0)+(a.1-b.1)*(a.1-b.1)+(a.2-b.2)*(a.2-b.2)}
            var best=Int.max,colors=[1,5,7,9]
            for a in 0..<15 {for b in a+1..<15 {
                let trial=[5,9,a,b]
                let error=(0..<15).reduce(0){sum,value in sum+histogram[value]*(trial.map{candidate in distance(value,candidate)}.min() ?? 0)}
                if error<best {best=error;colors=trial}
            }}
            let lookup=(0..<15).map {value in colors.indices.min{distance(value,colors[$0])<distance(value,colors[$1])}!}
            bytes=Data([1]+colors.map{UInt8($0)})
            for start in stride(from:0,to:pixels.count,by:4) {
                var packed:UInt8=0
                for j in 0..<min(4,pixels.count-start) {packed|=UInt8(lookup[Int(pixels[start+j])])<<(6-j*2)}
                bytes.append(packed)
            }
        }
        guard bytes.count<=Self.capacity else{throw TransferError.invalidMap}
        self.x=x;self.y=y;self.scale=scale;data=bytes
    }
    public func messages(id:UInt16)->[Data] {
        func le<T:FixedWidthInteger>(_ value:T)->Data {withUnsafeBytes(of:value.littleEndian){Data($0)}}
        var begin=Data([84,77,1,0x20]);begin+=le(id);begin+=le(UInt16(data.count));begin+=le(WireKit.crc32(data));begin+=le(x);begin+=le(y);begin+=le(scale)
        var result=[begin]
        for offset in stride(from:0,to:data.count,by:120) {result.append(Data([84,77,1,0x21])+le(id)+le(UInt16(offset))+data[offset..<min(offset+120,data.count)])}
        result.append(Data([84,77,1,0x22])+le(id));return result
    }
}
/// Check for a newer camera between small batches. An incomplete frame is
/// never displayed; the next begin packet safely replaces the partial buffer.
@discardableResult public func sendRaster(_ raster:WatchRaster,over channel:any Channel,id:UInt16,received:@Sendable(Data) async ->Void={_ in},checkpoint:@Sendable() async throws->Bool={true}) async throws ->Bool {
    let packets=raster.messages(id:id)
    for (i,packet) in packets.enumerated() {
        try Task.checkCancellation()
        if i%8==0 || i==packets.count-1 {guard try await checkpoint() else{return false}}
        try await channel.send(packet)
        if i==0 || i==packets.count-1 {
            let until=ContinuousClock.now + .seconds(8);var confirmed=false
            while ContinuousClock.now<until {
                let data=try await channel.recv(timeout:until-ContinuousClock.now)
                if let status=mapAcknowledgement(data,id:id) {guard status==0 else{throw TransferError.refused(status)};confirmed=true;break}
                await received(data)
            }
            guard confirmed else{throw TransferError.noAcknowledgement}
        }
    }
    return true
}

/// The watch already holds this exact full-quality image locally.
public struct WatchCachedMap:Sendable {
    public let viewport:WatchViewport,crc:UInt32
    public init?(message:Data) {
        guard message.count==18,message.prefix(4)==Data([84,77,1,0x12]) else{return nil}
        var camera=Data(message.prefix(14));camera[3]=0x11
        guard let viewport=WatchViewport(message:camera) else{return nil}
        self.viewport=viewport;crc=(0..<4).reduce(0){$0|UInt32(message[14+$1])<<(8*$1)}
    }
    public func matches(_ image:WatchRaster)->Bool {viewport.x==image.x && viewport.y==image.y && viewport.scale==image.scale && crc==WireKit.crc32(image.data)}
}
public struct WatchMapCacheStatus:Sendable {
    public let available:Bool,count:Int,capacity:Int,hits:Int,writes:Int,error:Int
    public init?(message d:Data) {
        guard [11,13].contains(d.count),d.prefix(4)==Data([84,77,1,0x14]),d[4]<=1,d[6]==8,d[5]<=d[6] else{return nil}
        available=d[4]==1;count=Int(d[5]);capacity=Int(d[6]);hits=Int(d[7])|Int(d[8])<<8;writes=Int(d[9])|Int(d[10])<<8;error=d.count==13 ? Int(Int16(bitPattern:UInt16(d[11])|UInt16(d[12])<<8)):0
    }
}
