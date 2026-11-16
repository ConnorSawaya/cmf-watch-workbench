import Foundation
import WireKit

public struct HealthPoint:Codable,Sendable,Identifiable {
    public var timestamp:UInt32
    public var value:Double
    public var metric:UInt16
    public var id:String {"\(metric)-\(timestamp)"}
}
public struct ActivityPoint:Codable,Sendable,Identifiable {
    public var timestamp:UInt32
    public var steps:UInt32
    public var meters:UInt32
    public var calories:UInt32
    public var id:UInt32 {timestamp}
}
public struct SleepRecord:Codable,Sendable,Identifiable {
    public var start:UInt32
    public var end:UInt32
    public var deep:UInt16
    public var light:UInt16
    public var rem:UInt16
    public var awake:UInt16
    public var id:UInt32 {start}
}
public struct WatchHealth:Codable,Sendable {
    public var points=[HealthPoint]()
    public var activity=[ActivityPoint]()
    public var sleep=[SleepRecord]()
    public var syncedAt:Date?
    public init() {}
    public mutating func merge(_ other:Self) {
        points=Array(Dictionary((points+other.points).map{($0.id,$0)},uniquingKeysWith:{$1}).values).sorted{$0.timestamp>$1.timestamp}.prefix(30000).map{$0}
        activity=Array(Dictionary((activity+other.activity).map{($0.id,$0)},uniquingKeysWith:{$1}).values).sorted{$0.timestamp>$1.timestamp}.prefix(15000).map{$0}
        sleep=Array(Dictionary((sleep+other.sleep).map{($0.id,$0)},uniquingKeysWith:{$1}).values).sorted{$0.start>$1.start}.prefix(100).map{$0}
        syncedAt=other.syncedAt ?? syncedAt
    }
    public mutating func ingest(ability:UInt16,command:UInt16,data:Data) {
        guard command==1 else{return}
        switch ability {
        case 0x56:
            guard data.count%32==0 else{return}
            for i in stride(from:0,to:data.count,by:32) {
                let ts=UInt32(data.readLE(i,4));guard Self.plausible(ts) else{continue}
                activity.append(ActivityPoint(timestamp:ts,steps:UInt32(data.readLE(i+4,4)),meters:UInt32(data.readLE(i+8,4)),calories:UInt32(data.readLE(i+12,4))))
            }
        case 0x53,0x55,0x9d,0xda,0xe0:
            let strideSize=ability==0xda ? 5:8
            guard data.count%strideSize==0 else{return}
            for i in stride(from:0,to:data.count,by:strideSize) {
                let ts=UInt32(data.readLE(i,4)),value=Double(data.readLE(i+4,strideSize-4))
                let range:ClosedRange<Double> = ability==0x55 ? 1...100:ability==0x9d ? 1...99:1...250
                if Self.plausible(ts),range.contains(value) {points.append(HealthPoint(timestamp:ts,value:value,metric:ability))}
            }
        case 0x58:
            guard data.count>=18,(data.count-18)%8==0 else{return}
            let a=UInt32(data.readLE(0,4)),b=UInt32(data.readLE(4,4))
            guard Self.plausible(a),b>a,b-a<=172800 else{return}
            sleep.append(SleepRecord(start:a,end:b,deep:UInt16(data.readLE(8,2)),light:UInt16(data.readLE(10,2)),rem:UInt16(data.readLE(12,2)),awake:UInt16(data.readLE(14,2))))
        default:break
        }
        if points.count>30000 {points.removeFirst(points.count-30000)}
        if activity.count>15000 {activity.removeFirst(activity.count-15000)}
        if sleep.count>100 {sleep.removeFirst(sleep.count-100)}
    }
    static func plausible(_ timestamp:UInt32)->Bool {timestamp>=1577836800 && timestamp<=4102444800}
}
struct StockRawFrame {
    let ability:UInt16
    let command:UInt16
    let count:Int
    let index:Int
    let body:Data
}
struct StockFrameReader {
    var buffer=Data()
    mutating func feed(_ data:Data)->[StockRawFrame] {
        buffer.append(data);var out=[StockRawFrame]()
        while true {
            guard let start=buffer.firstIndex(of:0xf5) else{buffer=Data();break}
            buffer=Data(buffer[start...]);guard buffer.count>=11 else{break}
            let n=Int(buffer.readBE(1,2)),a=UInt16(buffer.readBE(3,2)),c=UInt16(buffer.readBE(9,2))
            guard n<=4096,!(a==0xffff && c==0x48 && n<4) else{buffer.removeFirst();continue}
            let size=a==0xffff && c==0x48 ? n-4:n
            guard buffer.count>=11+size else{break}
            out.append(StockRawFrame(ability:a,command:c,count:Int(buffer.readBE(5,2)),index:Int(buffer.readBE(7,2)),body:Data(buffer[11..<11+size])))
            buffer=Data(buffer[(11+size)...])
        }
        return out
    }
}
struct StockChunks {
    var partial=[UInt32:(Int,Int,Data)]()
    mutating func append(_ f:StockRawFrame,plain:Data)->Data? {
        let id=UInt32(f.ability)<<16|UInt32(f.command)
        guard f.count>1 else{return plain}
        guard f.count<=1024,f.index>=1,f.index<=f.count else{partial[id]=nil;return nil}
        if f.index==1 {if partial.count>=16 {partial.removeAll()};partial[id]=(f.count,1,Data())}
        guard var p=partial[id],p.0==f.count,p.1==f.index,p.2.count+plain.count<=131072 else{partial[id]=nil;return nil}
        p.2.append(plain);p.1+=1
        if f.index==f.count {partial[id]=nil;return p.2}
        partial[id]=p;return nil
    }
}
