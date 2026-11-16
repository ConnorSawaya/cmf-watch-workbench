import Foundation
import WireKit

public struct WatchBattery:Equatable,Sendable {
    public let percent:Int
    public let charging:Bool
    public init(data:Data)throws {
        guard data.count==2,data[0]<=100,data[1]<=1 else{throw StockFeatureError.invalidData}
        percent=Int(data[0]);charging=data[1]==1
    }
}

public enum StockFeatureError:LocalizedError {
    case invalidData,unavailable,clockSetupRequired
    public var errorDescription:String? {switch self {case .invalidData:"The watch returned an unsupported data format.";case .unavailable:"The watch did not acknowledge this feature. No change was confirmed.";case .clockSetupRequired:"Finish the standard watch setup on the Device tab first."}}
}
public struct WatchAlarm:Identifiable,Equatable,Sendable {
    public var id:UInt8
    public var seconds:UInt32
    public var enabled:Bool
    public var weekdays:UInt8
    public var flag:UInt8
    public var label:String
    public init(id:UInt8,seconds:UInt32=25200,enabled:Bool=true,weekdays:UInt8=0,flag:UInt8=0,label:String="Alarm") {
        self.id=id;self.seconds=seconds;self.enabled=enabled;self.weekdays=weekdays;self.flag=flag;self.label=label
    }
    public static func decode(_ data:Data)throws->[Self] {
        guard data.count%40==0,data.count<=200 else{throw StockFeatureError.invalidData}
        return try stride(from:0,to:data.count,by:40).map {i in
            let seconds=data.readLE(i,4)
            guard seconds<86400,data[i+4]<5 else{throw StockFeatureError.invalidData}
            return Self(id:data[i+4],seconds:UInt32(seconds),enabled:data[i+5] != 0,weekdays:data[i+6],flag:data[i+7],label:String(decoding:data[(i+8)..<(i+40)].prefix(while:{$0 != 0}),as:UTF8.self))
        }
    }
    public static func encode(_ alarms:[Self])throws->Data {
        guard alarms.count<=5,Set(alarms.map(\.id)).count==alarms.count else{throw StockFeatureError.invalidData}
        if alarms.isEmpty {return Data([0])}
        var d=Data()
        for (index,a) in alarms.sorted(by:{$0.id<$1.id}).enumerated() {
            guard a.id<5,a.seconds<86400,a.weekdays<128 else{throw StockFeatureError.invalidData}
            d.writeBE(UInt64(a.seconds),4);d.append(contentsOf:[UInt8(index),a.enabled ? 1:0,a.weekdays,a.flag]);d.append(fixedString(a.label,32))
        }
        return d
    }
}
public struct WatchReminder:Equatable,Sendable {
    public var enabled:Bool
    public var minutes:UInt16
    public var quietStart:UInt32
    public var quietEnd:UInt32
    public init(enabled:Bool=false,minutes:UInt16=60,quietStart:UInt32=79200,quietEnd:UInt32=28800) {self.enabled=enabled;self.minutes=minutes;self.quietStart=quietStart;self.quietEnd=quietEnd}
    public init(data:Data)throws {
        guard data.count==11 else{throw StockFeatureError.invalidData}
        enabled=data[0] != 0;minutes=UInt16(data.readBE(1,2));quietStart=UInt32(data.readBE(3,4));quietEnd=UInt32(data.readBE(7,4))
        guard minutes<=1440,quietStart<86400,quietEnd<86400 else{throw StockFeatureError.invalidData}
    }
    public func encoded()throws->Data {
        guard (1...1440).contains(minutes),quietStart<86400,quietEnd<86400 else{throw StockFeatureError.invalidData}
        var d=Data([enabled ? 1:0]);d.writeBE(UInt64(minutes),2);d.writeBE(UInt64(quietStart),4);d.writeBE(UInt64(quietEnd),4);return d
    }
}
public struct WatchContact:Identifiable,Equatable,Sendable {
    public var id=UUID()
    public var name:String
    public var number:String
    public init(name:String,number:String) {self.name=name;self.number=number}
    public static func encode(_ contacts:[Self])throws->Data {
        guard contacts.count<=20 else{throw StockFeatureError.invalidData}
        if contacts.isEmpty {return Data([0])}
        var d=Data()
        for c in contacts {guard !c.name.isEmpty,!c.number.isEmpty,c.name.utf8.count<=32,c.number.utf8.count<=25 else{throw StockFeatureError.invalidData};d.append(fixedString(c.name,32));d.append(fixedString(c.number,25))};return d
    }
    public static func decode(_ d:Data)throws->[Self] {
        if d.isEmpty {return []}
        guard d.count%57==0,d.count<=1140 else{throw StockFeatureError.invalidData}
        return stride(from:0,to:d.count,by:57).map {i in Self(name:String(decoding:d[i..<i+32].prefix(while:{$0 != 0}),as:UTF8.self),number:String(decoding:d[i+32..<i+57].prefix(while:{$0 != 0}),as:UTF8.self))}
    }
}
public enum WatchSetting:Sendable {
    case distanceImperial(Bool),temperatureFahrenheit(Bool),twelveHour(Bool),wristWake(Bool)
    case monitoring(kind:UInt8,enabled:Bool),goals(steps:UInt32,meters:UInt32,kcal:UInt16)
    case profile(height:UInt8,weight:UInt8,age:UInt8,male:Bool)
    case findWatch(Bool)
    public func packet()throws->(UInt16,UInt16,Data) {
        switch self {
        case .distanceImperial(let b):return (0xffff,0x9067,Data([1,b ? 1:0]))
        case .temperatureFahrenheit(let b):return (0xffff,0x9068,Data([1,b ? 1:0]))
        case .twelveHour(let b):return (0x5f,1,Data([b ? 1:0]))
        case .wristWake(let b):return (0x62,1,Data([b ? 1:0]))
        case .monitoring(let kind,let b):guard [1,2,4].contains(kind) else{throw StockFeatureError.invalidData};return (0x9b,1,Data([kind,b ? 1:0]))
        case .goals(let steps,let meters,let kcal):
            guard (2000...30000).contains(steps),(1000...99000).contains(meters),(100...5000).contains(kcal) else{throw StockFeatureError.invalidData}
            var d=Data();d.writeBE(UInt64(steps),4);d.writeBE(UInt64(meters),4);d.writeBE(UInt64(kcal),2);return (0x5e,1,d)
        case .profile(let h,let w,let a,let male):guard h>=80,w>=20,a>=5,a<=120 else{throw StockFeatureError.invalidData};return (0x95,1,Data([h,w,a,male ? 1:0]))
        case .findWatch(let b):return (0x5d,1,Data([b ? 1:0]))
        }
    }
}
func fixedString(_ text:String,_ count:Int)->Data {
    var result=Data()
    for c in text {let b=Data(String(c).utf8);if result.count+b.count>count {break};result.append(b)}
    result.append(Data(count:count-result.count));return result
}
extension Data {
    func readBE(_ offset:Int,_ count:Int)->UInt64 {(0..<count).reduce(0){$0<<8|UInt64(self[offset+$1])}}
    func readLE(_ offset:Int,_ count:Int)->UInt64 {(0..<count).reduce(0){$0|UInt64(self[offset+$1])<<(8*$1)}}
    mutating func writeBE(_ value:UInt64,_ count:Int){for i in (0..<count).reversed(){append(UInt8(truncatingIfNeeded:value>>(8*i)))}}
    mutating func writeLE(_ value:UInt64,_ count:Int){for i in 0..<count {append(UInt8(truncatingIfNeeded:value>>(8*i)))}}
}
