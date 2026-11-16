import Foundation
import CryptoKit

public enum CompanionPolicyError:LocalizedError {
    case untestedPackage, unsupportedFirmware, chargeWatch, closeWatchApp, clockMovedBack
    public var errorDescription:String? {
        switch self {
        case .untestedPackage: "This package is not in this build's tested app list. Use a companion build that includes and verifies the new package."
        case .unsupportedFirmware: "This app build supports Watch Pro 2 firmware 1.0.0.73 only."
        case .chargeWatch: "Charge the watch to at least 30% and refresh its battery before installing an app."
        case .closeWatchApp: "Close Custom Apps on the watch before installing. Your existing app has not been changed."
        case .clockMovedBack: "Clock sync was stopped because the iPhone clock or time zone moved backward. This prevents a potentially unsafe clock correction."
        }
    }
}
public struct TestedPackage:Codable,Sendable {
    public let name:String
    public let kind:Int
    public let version:UInt32
    public let bytes:Int
    public let sha256:String
    public init(name:String,kind:Int,version:UInt32,bytes:Int,sha256:String) {self.name=name;self.kind=kind;self.version=version;self.bytes=bytes;self.sha256=sha256}
    public func verify(_ package:ValidatedPackage)throws {
        let hash=SHA256.hash(data:package.data).map{String(format:"%02x",$0)}.joined()
        guard package.header.name==name,package.header.kind==kind,package.header.version==version,package.data.count==bytes,hash==sha256 else{throw CompanionPolicyError.untestedPackage}
    }
}
public enum CompanionPolicy {
    public static func validateInstall(firmware:String?,battery:Int?,batteryAge:TimeInterval?,runningSlot:UInt8)throws {
        guard firmware=="1.0.0.73" else{throw CompanionPolicyError.unsupportedFirmware}
        guard let battery,battery>=30,let batteryAge,batteryAge>=0,batteryAge<120 else{throw CompanionPolicyError.chargeWatch}
        guard runningSlot==255 else{throw CompanionPolicyError.closeWatchApp}
    }
    public static func syncDue(now:Date,lastSync:Date?,lastAttempt:Date?,foreground:Bool,enabled:Bool,busy:Bool,sharingGPS:Bool,minimumInterval:TimeInterval=900)->Bool {
        guard enabled,foreground,!busy,!sharingGPS else{return false}
        guard lastSync.map({now.timeIntervalSince($0)>=minimumInterval}) ?? true else{return false}
        return lastAttempt.map{now.timeIntervalSince($0)>=300} ?? true
    }
    public static func validateClock(epoch:TimeInterval,offset:Int,lastEpoch:TimeInterval?,lastOffset:Int?,elapsed:TimeInterval)throws {
        guard let lastEpoch,let lastOffset else{return}
        // Stock firmware can enter recovery on large backward local-time corrections.
        guard epoch+Double(offset) >= lastEpoch+Double(lastOffset)+max(0,elapsed)-90 else{throw CompanionPolicyError.clockMovedBack}
    }
}
