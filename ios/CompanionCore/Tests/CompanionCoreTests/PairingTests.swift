import XCTest
import CryptoKit
import WireKit
@testable import CompanionCore

actor MockStockState {
    let secret=Data(repeating:0x12,count:16)
    let nonce=Data(repeating:0x34,count:16)
    var auth:Data?
    var key:Data?
    var phoneNames=0
    var commands=[(String,UInt16)]()
    var served=Data()
    var endSent=false
    let badChallenge:Bool
    let invalidRange:Bool
    init(badChallenge:Bool=false,invalidRange:Bool=false){self.badChallenge=badChallenge;self.invalidRange=invalidRange}
    func write(_ uuid:String,_ d:Data)->Data? {
        if uuid==Uuid.shellWrite {
            if String(decoding:d,as:UTF8.self).contains("GETVERSION") {return Data("GETVERSION:1.0.0.73,OK\r\n".utf8)}
            return Data(("GETSECRET:"+secret.map{String(format:"%02x",$0)}.joined()+",OK\r\n").utf8)
        }
        guard d.count>=11 else{return nil}
        let cmd=UInt16(d[9])<<8 | UInt16(d[10]);commands.append((uuid,cmd))
        let raw=Data(d.dropFirst(11))
        switch cmd {
        case 0x8047:
            let rnd=Data(raw.prefix(16));let rnd2=Data(repeating:0x56,count:16)
            auth=Data(SHA256.hash(data:rnd+rnd2+secret).prefix(16))
            var signature=Data(SHA256.hash(data:rnd2+secret));if badChallenge{signature[0] ^= 1}
            var f=WireKit.frame(c2:0x0048,payload:rnd2+signature,key:nil);f.removeLast(4);return f
        case 0x8049:
            phoneNames+=1
            guard phoneNames>1,let auth,WireKit.open(auth,raw) != nil else{return nil}
            return WireKit.frame(c2:0x0049,payload:Data(repeating:0,count:6),key:auth)
        case 0x804B:
            guard let auth else{return nil};key=Data(SHA256.hash(data:nonce+auth).prefix(16))
            return WireKit.frame(c2:0x004C,payload:nonce,key:auth)
        case 0x804D: return WireKit.frame(c2:0x0004,payload:Data([1]),key:key)
        case 0x9052:return WireKit.frame(c2:0xA052,payload:Data([1]),key:key)
        case 0x9040:
            return WireKit.frame(c2:0xA040,payload:Data([1]),key:key)+request(offset:invalidRange ? 1024:512,length:invalidRange ? 24:512)
        case 0x9042:
            served.append(raw.dropLast(4))
            if served.count==512 {return request(offset:0,length:512)}
            if served.count==1024 {return WireKit.frame(c2:0xA041,payload:Data([1]),key:key)}
            return nil
        case 0x9041:endSent=true;return nil
        default:return nil
        }
    }
    private func request(offset:UInt32,length:UInt32)->Data {
        var payload=Data()
        for n in [offset,length] {payload.append(contentsOf:[UInt8(n>>24),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)])}
        payload.append(Data(count:5));return WireKit.frame(c2:0xA042,payload:payload,key:key)
    }
}
final class MockStockLink:Link,@unchecked Sendable {
    let state:MockStockState
    private let lock=NSLock()
    private var handler:(@Sendable(String,Data)->Void)?
    init(badChallenge:Bool=false,invalidRange:Bool=false){state=MockStockState(badChallenge:badChallenge,invalidRange:invalidRange)}
    func onNotify(_ callback:@escaping @Sendable(String,Data)->Void){lock.withLock{handler=callback}}
    func write(_ uuid:String,_ data:Data) async throws {
        guard let reply=await state.write(uuid,data) else{return}
        let h=lock.withLock{handler}
        h?(uuid==Uuid.shellWrite ? Uuid.shellNotify:Uuid.cmdNotify,reply)
    }
}
final class PairingTests:XCTestCase {
    func testFreshPairAndPullFirmwareProtocol() async throws {
        let link=MockStockLink();let connection=StockConnection(link:link);await connection.attach()
        let auth=try await connection.pair();XCTAssertEqual(auth.count,16)
        let version=try await connection.readVersion();XCTAssertEqual(version,"1.0.0.73")
        var image=Data(count:1024);image.replaceSubrange(0..<4,with:Data("AOTA".utf8))
        let hash=SHA256.hash(data:image).map{String(format:"%02x",$0)}.joined()
        let candidate=try FirmwareCandidate(data:image,expectedSHA256:hash,expectedBytes:1024)
        try await connection.upload(candidate){_ in}
        let commands=await link.state.commands
        XCTAssertTrue(commands.contains(where:{$0.0==StockConnection.otaWrite && $0.1==0x9040}))
        XCTAssertFalse(commands.contains(where:{$0.0==Uuid.cmdWrite && $0.1==0x9040}))
        let sent=await link.state.served;XCTAssertEqual(sent,Data(image[512...])+Data(image[..<512]))
        let ended=await link.state.endSent;XCTAssertTrue(ended)
        await connection.close()
    }
    func testRejectsBadPairingSignature() async throws {
        let link=MockStockLink(badChallenge:true);let c=StockConnection(link:link);await c.attach()
        do {_ = try await c.pair();XCTFail("Invalid challenge accepted")}catch{XCTAssertTrue(error is PairingError)}
        await c.close()
    }
    func testQRParsesLocallyAndRejectsForeignLinks() throws {
        let qr=try WatchPairingCode("https://did6d9jhya79g.cloudfront.net/#/qr?p=wapp1&M=AABBCCDDEEFF&P=00000000&D=00000000000000000000000000000000&C=16")
        XCTAssertEqual(qr.suffix,"EEFF")
        XCTAssertThrowsError(try WatchPairingCode("https://example.com/#/qr?p=wapp1&M=AABBCCDDEEFF"))
        XCTAssertThrowsError(try WatchPairingCode("https://did6d9jhya79g.cloudfront.net/#/qr?p=wapp1&M=AABBCCDDEEFF&M=000000000000"))
    }
    func testOutOfBoundsFirmwarePullNeverCommits() async throws {
        let link=MockStockLink(invalidRange:true);let c=StockConnection(link:link);await c.attach();_ = try await c.pair()
        var data=Data(count:1024);data.replaceSubrange(0..<4,with:Data("AOTA".utf8))
        let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        do {try await c.upload(FirmwareCandidate(data:data,expectedSHA256:hash,expectedBytes:1024)){_ in};XCTFail("Invalid pull accepted")}catch {XCTAssertTrue(error is PairingError)}
        let committed=await link.state.endSent;XCTAssertFalse(committed)
        await c.close()
    }
    func testCandidatePinsExactBytes() {
        XCTAssertThrowsError(try FirmwareCandidate(data:Data("AOTA".utf8),expectedSHA256:String(repeating:"0",count:64),expectedBytes:4))
    }
}
