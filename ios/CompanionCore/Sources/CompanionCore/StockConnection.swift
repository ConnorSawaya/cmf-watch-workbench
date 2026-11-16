import Foundation
import CryptoKit
import Security
import WireKit

public enum PairingError:LocalizedError {
    case timeout,invalidChallenge,resetDuringPairing,invalidFirmware,wrongVersion,updateRejected
    public var errorDescription:String? {
        switch self {
        case .timeout:"The watch did not answer. Keep its setup screen open and retry."
        case .invalidChallenge:"The watch's pairing challenge could not be verified."
        case .resetDuringPairing:"The watch cleared pairing during setup. Retry pairing without closing the pairing popup."
        case .invalidFirmware:"This firmware file does not match the verified build for this device."
        case .wrongVersion:"This firmware requires Watch Pro 2 / JX402 version 1.0.0.73."
        case .updateRejected:"The watch rejected the firmware update. No successful update was confirmed."
        }
    }
}
actor PairInbox<T:Sendable> {
    private var values=[T]()
    private var waiter:(UUID,CheckedContinuation<T?,Never>)?
    func put(_ value:T) {if let w=waiter {waiter=nil;w.1.resume(returning:value)}else{if values.count>=64 {values.removeFirst()};values.append(value)}}
    func next(_ timeout:Duration) async -> T? {
        if !values.isEmpty {return values.removeFirst()}
        let id=UUID()
        return await withCheckedContinuation {c in
            waiter=(id,c)
            Task {try? await Task.sleep(for:timeout);self.expire(id)}
        }
    }
    private func expire(_ id:UUID) {if let w=waiter,w.0==id {waiter=nil;w.1.resume(returning:nil)}}
    func drain() {values=[]}
}
public struct FirmwareCandidate:Sendable {
    public let data:Data
    public let hash:String
    public init(data:Data,expectedSHA256:String,expectedBytes:Int) throws {
        guard expectedSHA256.count==64,data.count==expectedBytes,data.count>=1024,data.count<=64*1024*1024,
              data.prefix(4)==Data("AOTA".utf8) else {throw PairingError.invalidFirmware}
        let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        guard hash==expectedSHA256 else {throw PairingError.invalidFirmware}
        self.data=data;self.hash=hash
    }
}
public actor StockConnection {
    public static let otaWrite="02F00000-0000-0000-0000-00000000FF01"
    public static let otaNotify="02F00000-0000-0000-0000-00000000FF02"
    private let link:any Link
    private var key:Data?
    private var parsers=[String:StockFrameReader]()
    private var chunks=StockChunks()
    private var health=WatchHealth()
    private let abilities=PairInbox<(UInt16,UInt16,Data)>()
    private let replies=PairInbox<(UInt16,Data)>()
    private let shell=PairInbox<Data>()
    private var streamEnd:AsyncStream<(String,Data)>.Continuation?
    private var reader:Task<Void,Never>?
    public init(link:any Link) {self.link=link}
    public func attach() {
        let (stream,sink)=AsyncStream<(String,Data)>.makeStream(bufferingPolicy:.bufferingNewest(128));streamEnd=sink
        link.onNotify {uuid,data in sink.yield((uuid.uppercased(),data))}
        reader=Task { [weak self] in for await (uuid,data) in stream {guard let self else{break};await self.feed(uuid,data)} }
    }
    public func close() {streamEnd?.finish();reader?.cancel();reader=nil}
    private func feed(_ uuid:String,_ data:Data) async {
        if uuid==Uuid.shellNotify {await shell.put(data)}
        if uuid==Uuid.cmdNotify || uuid==Self.otaNotify || uuid=="02F00000-0000-0000-0000-00000000FFE2" {
            var parser=parsers[uuid] ?? StockFrameReader()
            let frames=parser.feed(data);parsers[uuid]=parser
            for f in frames {
                if f.ability==system {await replies.put((f.command,f.body))}
                else if let key,let plain=f.body.isEmpty ? Data():WireKit.open(key,f.body),let full=chunks.append(f,plain:plain) {
                    health.ingest(ability:f.ability,command:f.command,data:full)
                    await abilities.put((f.ability,f.command,full))
                }
            }
        }
    }
    public func readVersion() async throws -> String {try await at("GETVERSION")}
    private func at(_ field:String) async throws->String {
        await shell.drain();try await link.write(Uuid.shellWrite,Data("AT \(field)\r\n".utf8))
        var reply="";let end=ContinuousClock.now + .seconds(7)
        while ContinuousClock.now<end {
            guard let d=await shell.next(end-ContinuousClock.now) else{throw PairingError.timeout}
            reply+=String(decoding:d,as:UTF8.self)
            guard reply.utf8.count<=512 else{throw PairingError.invalidChallenge}
            if reply.contains(",OK") {
                let text=reply.trimmingCharacters(in:.whitespacesAndNewlines)
                guard text.hasPrefix(field+":"),text.hasSuffix(",OK") else{throw PairingError.invalidChallenge}
                return String(text.dropFirst(field.count+1).dropLast(3))
            }
        }
        throw PairingError.timeout
    }
    private func exchange(_ cmd:UInt16,_ payload:Data,reply:UInt16,key:Data?,timeout:Duration = .seconds(7)) async throws -> Data {
        await replies.drain();try await link.write(Uuid.cmdWrite,WireKit.frame(c2:cmd,payload:payload,key:key))
        return try await wait(reply,key:key,timeout:timeout)
    }
    private func wait(_ expected:UInt16,key:Data?,timeout:Duration = .seconds(7)) async throws -> Data {
        let end=ContinuousClock.now+timeout
        while ContinuousClock.now<end {
            guard let (cmd,body)=await replies.next(end-ContinuousClock.now) else{throw PairingError.timeout}
            if cmd==0xA061 {throw PairingError.invalidChallenge}
            guard cmd==expected else{continue}
            if let key {
                if let opened=WireKit.open(key,body){return opened}
                if WireKit.open(Data(count:16),body) != nil {throw PairingError.resetDuringPairing}
            }else{return body}
        }
        throw PairingError.timeout
    }
    public func pair() async throws -> Data {
        let secretHex=try await at("GETSECRET")
        guard let secret=channelKey(secretHex:secretHex) else{throw PairingError.invalidChallenge}
        var random=Data(count:16)
        let status=random.withUnsafeMutableBytes {SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!)}
        guard status==errSecSuccess else{throw PairingError.invalidChallenge}
        let response=try await exchange(0x8047,random+Data(SHA256.hash(data:random+secret)),reply:0x0048,key:nil)
        guard response.count==48 else{throw PairingError.invalidChallenge}
        let rnd2=Data(response.prefix(16))
        guard Data(response.suffix(32))==Data(SHA256.hash(data:rnd2+secret)) else{throw PairingError.invalidChallenge}
        let auth=Data(SHA256.hash(data:random+rnd2+secret).prefix(16));let phone=Data([0xA5])+Data("CMF Watch Pro 2".utf8)
        try await link.write(Uuid.cmdWrite,WireKit.frame(c2:0x8049,payload:phone,key:auth))
        _ = try await exchange(0x8049,phone,reply:0x0049,key:auth)
        let nonce=try await exchange(0x804B,Data([0xA5]),reply:0x004C,key:auth)
        guard nonce.count>=16 else{throw PairingError.invalidChallenge}
        let session=Data(SHA256.hash(data:Data(nonce.prefix(16))+auth).prefix(16))
        _ = try await exchange(0x804D,Data([0xA5]),reply:0x0004,key:session)
        key=session;return auth
    }
    public func resume(auth:Data) async throws {
        guard auth.count==16 else{throw PairingError.invalidChallenge}
        _ = try await exchange(0x8049,Data([0xA5])+Data("CMF Watch Pro 2".utf8),reply:0x0049,key:auth)
        let nonce=try await exchange(0x804B,Data([0xA5]),reply:0x004C,key:auth)
        guard nonce.count>=16 else{throw PairingError.invalidChallenge}
        let s=Data(SHA256.hash(data:Data(nonce.prefix(16))+auth).prefix(16))
        _ = try await exchange(0x804D,Data([0xA5]),reply:0x0004,key:s);key=s
    }
    public func readFeature(_ ability:UInt16) async throws->Data {
        try await feature(ability:ability,command:2,payload:Data([0xa5]),expect:1)
    }
    public func readBattery() async throws->WatchBattery {
        try WatchBattery(data:await feature(ability:0x5c,command:1,payload:Data([0xa5]),expect:1))
    }
    public func initializeClock(epoch:UInt32,offsetMilliseconds:Int32) async throws {
        guard let key else{throw PairingError.invalidChallenge}
        var payload=Data();payload.writeBE(UInt64(epoch),4);payload.writeBE(UInt64(UInt32(bitPattern:offsetMilliseconds)),4)
        try await link.write(Uuid.cmdWrite,WireKit.frame(c2:0x8004,payload:payload,key:key))
    }
    public func writeFeature(_ ability:UInt16,_ data:Data) async throws {
        _ = try await feature(ability:ability,command:1,payload:data,expect:3)
    }
    public func apply(_ setting:WatchSetting) async throws {
        let (a,c,data)=try setting.packet()
        if a==system {
            guard let key else{throw PairingError.invalidChallenge}
            let r=try await exchange(c,data,reply:c|0xa000,key:key)
            guard r.isEmpty || r.first==0 || r.first==1 else{throw StockFeatureError.unavailable}
            if c==0x9067 || c==0x9068 {
                let current=try await exchange(c,Data([0]),reply:c|0xa000,key:key)
                guard current==data else{throw StockFeatureError.unavailable}
            }
        }else{try await writeFeature(a,data)}
    }
    private func feature(ability:UInt16,command:UInt16,payload:Data,expect:UInt16) async throws->Data {
        guard let key else{throw PairingError.invalidChallenge};await abilities.drain()
        let count=max(1,(payload.count+127)/128)
        for i in 0..<count {
            let part=Data(payload[(i*128)..<min(payload.count,(i+1)*128)])
            var f=WireKit.frame(c2:command,payload:part,key:key)
            f[3]=UInt8(ability>>8);f[4]=UInt8(ability&255);f[5]=UInt8(count>>8);f[6]=UInt8(count&255);f[7]=UInt8((i+1)>>8);f[8]=UInt8((i+1)&255)
            try await link.write(Uuid.cmdWrite,f)
        }
        let until=ContinuousClock.now + .seconds(6)
        while ContinuousClock.now<until {
            guard let (a,c,d)=await abilities.next(until-ContinuousClock.now) else{break}
            if a==ability,c==expect {return d}
        }
        throw StockFeatureError.unavailable
    }
    public func syncHealth() async throws->WatchHealth {
        guard let key else{throw PairingError.invalidChallenge}
        let ready=try await exchange(0x8005,Data([0xa5]),reply:0x0005,key:key)
        guard ready.first==1 else{throw StockFeatureError.unavailable}
        _ = try await exchange(0x9057,Data([0xa5]),reply:0xa057,key:key,timeout:.seconds(15))
        let until=ContinuousClock.now + .seconds(240)
        while ContinuousClock.now<until {
            try Task.checkCancellation()
            guard let (cmd,body)=await replies.next(.seconds(20)) else{continue}
            if cmd==0x0005,WireKit.open(key,body)?.first==2 {health.syncedAt=Date();return health}
        }
        throw PairingError.timeout
    }
    public static let faceWrite="02F00000-0000-0000-0000-00000000FFE1"
    private func sendFace(_ command:UInt16,_ payload:Data,plain:Bool=false) async throws {
        guard let key else{throw PairingError.invalidChallenge}
        let limit=plain ? 160:155,count=max(1,(payload.count+limit-1)/limit)
        guard count<=65535 else{throw WatchFaceError.invalidRequest}
        for i in 0..<count {
            try Task.checkCancellation()
            let part=Data(payload[i*limit..<min(payload.count,(i+1)*limit)])
            var frame=WireKit.frame(c2:command,payload:part,key:plain ? nil:key)
            frame[5]=UInt8(count>>8);frame[6]=UInt8(count&255);frame[7]=UInt8((i+1)>>8);frame[8]=UInt8((i+1)&255)
            try await link.writeWithoutResponse(Self.faceWrite,frame)
            if plain {try await Task.sleep(for:.milliseconds(10))}
        }
    }
    public func uploadFace(_ face:FaceFile,id:UInt32,delete:Bool=false,progress:@Sendable(Int) async->Void={_ in}) async throws {
        guard let key else{throw PairingError.invalidChallenge}
        guard id>=(delete ? 7:10000),id<0x80000000 else{throw WatchFaceError.invalidRequest}
        guard try await readVersion()=="1.0.0.73" else{throw PairingError.wrongVersion}
        await replies.drain();try await sendFace(0x8052,Data([0xa5]))
        let first=try await wait(0x52,key:key);guard first.first==1 else{throw WatchFaceError.rejected(first.first ?? 255)}
        var header=Data([3])
        for n:UInt32 in [delete ? id:0,delete ? 0:id,UInt32(face.data.count)] {header.append(contentsOf:(0..<4).map{UInt8(truncatingIfNeeded:n>>(8*$0))})}
        await replies.drain();try await sendFace(0x9075,header)
        let second=try await wait(0xa075,key:key);guard second.first==1 else{throw WatchFaceError.rejected(second.first ?? 255)}
        let until=ContinuousClock.now + .seconds(1800);var ranges=[Range<Int>]()
        while ContinuousClock.now<until {
            try Task.checkCancellation()
            guard let (command,raw)=await replies.next(.seconds(25)) else{throw PairingError.timeout}
            guard let body=WireKit.open(key,raw) else{continue}
            if command==0xa065 {
                try await sendFace(0x9065,Data([0xa5]))
                guard body.first==1 else{if body.first==10{throw WatchFaceError.notActivated};throw WatchFaceError.rejected(body.first ?? 255)}
                guard ranges.reduce(0,{$0+$1.count})==face.data.count else{throw WatchFaceError.invalidRequest}
                await progress(face.data.count);return
            }
            guard command==0xa064 else{continue}
            guard body.count>=9 else{throw WatchFaceError.invalidRequest}
            let offset=(0..<4).reduce(0){$0|Int(body[$1])<<(8*(3-$1))},length=(0..<4).reduce(0){$0|Int(body[4+$1])<<(8*(3-$1))}
            guard offset<=face.data.count,length>0,length<=face.data.count-offset,length<=65535*160 else{throw WatchFaceError.invalidRequest}
            try await sendFace(0x9064,Data(face.data[offset..<offset+length]),plain:true)
            var merged=offset..<offset+length,keep=[Range<Int>]()
            for r in ranges {if r.upperBound<merged.lowerBound || merged.upperBound<r.lowerBound{keep.append(r)}else{merged=min(r.lowerBound,merged.lowerBound)..<max(r.upperBound,merged.upperBound)}}
            keep.append(merged);ranges=keep.sorted{$0.lowerBound<$1.lowerBound}
            await progress(ranges.reduce(0,{$0+$1.count}))
        }
        throw PairingError.timeout
    }
    public func upload(_ image:FirmwareCandidate,progress:@Sendable(Int)->Void) async throws {
        guard let key else{throw PairingError.invalidChallenge}
        guard try await readVersion()=="1.0.0.73" else{throw PairingError.wrongVersion}
        let accepted=try await exchange(0x9052,Data([0xA5]),reply:0xA052,key:key)
        guard accepted.first==1 else{throw PairingError.updateRejected}
        await replies.drain()
        try await link.write(Self.otaWrite,WireKit.frame(c2:0x9040,payload:Data([1,0,0,0x5A]),key:key))
        guard try await wait(0xA040,key:key).first==1 else{throw PairingError.updateRejected}
        let until=ContinuousClock.now + .seconds(2700);var served=0
        while ContinuousClock.now<until {
            guard let (cmd,body)=await replies.next(.seconds(30)),let data=WireKit.open(key,body) else{throw PairingError.timeout}
            if cmd==0xA041 {
                guard data.first==1 else{throw PairingError.updateRejected}
                try await link.write(Uuid.cmdWrite,WireKit.frame(c2:0x9041,payload:Data([0xA5]),key:key));return
            }
            if cmd==0xA043 || cmd==0xA044 {throw PairingError.updateRejected}
            guard cmd==0xA042 else{continue}
            guard data.count>=8 else{throw PairingError.updateRejected}
            let off=(0..<4).reduce(0){$0 | Int(data[$1]) << (8*(3-$1))}
            let length=(0..<4).reduce(0){$0 | Int(data[4+$1]) << (8*(3-$1))}
            guard off>=0,length>0,off<=image.data.count,length<=image.data.count-off,length<=224*65535 else{throw PairingError.updateRejected}
            let count=(length+223)/224
            for i in 0..<count {
                let start=off+224*i;let plain=Data(image.data[start..<min(start+224,off+length)])
                var f=WireKit.frame(c2:0x9042,payload:plain,key:nil)
                f[5]=UInt8(count>>8);f[6]=UInt8(count&255);f[7]=UInt8((i+1)>>8);f[8]=UInt8((i+1)&255)
                try await link.write(Self.otaWrite,f);served+=plain.count;progress(served)
            }
        }
        throw PairingError.timeout
    }
}
