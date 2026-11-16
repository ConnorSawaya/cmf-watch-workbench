import XCTest
import WireKit
@testable import CompanionCore
final class TransferTests:XCTestCase {
    func testActualPackagesAndCorruption() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["trail-map","loader"] {
            let url=root.appendingPathComponent("firmware/wp2-apps/target/\(name).wp2app")
            guard FileManager.default.fileExists(atPath:url.path) else{throw XCTSkip("Build the watch packages first")}
            let d=try Data(contentsOf:url);let p=try ValidatedPackage(d);XCTAssertEqual(p.header.name,name)
            var broken=d;broken[broken.count-1] ^= 1;XCTAssertThrowsError(try ValidatedPackage(broken))
            XCTAssertThrowsError(try ValidatedPackage(Data(d.dropLast())))
        }
    }
    func testMapChunkBoundsAndAcknowledgement() throws {
        let s=try WatchSnapshot(x:100000,y:100000,metersPerPixel:8,label:"Public fixture",segments:Array(repeating:WatchSegment(x1:0,y1:0,x2:100,y2:100,kind:1),count:400))
        XCTAssertEqual(s.data.count,3648)
        let m=s.messages(id:42);XCTAssertTrue(m.allSatisfy({$0.count<=128}));XCTAssertEqual(m.count,33)
        let bytes=m.dropFirst().dropLast().reduce(Data()) {$0+Data($1.dropFirst(8))};XCTAssertEqual(bytes,s.data)
        XCTAssertEqual(mapAcknowledgement(Data([84,77,1,128,42,0,0]),id:42),0)
        XCTAssertNil(mapAcknowledgement(Data([84,77,1,128,41,0,0]),id:42))
        XCTAssertThrowsError(try WatchSnapshot(x:0,y:0,metersPerPixel:0,label:"",segments:[]))
    }
    func testMapOverLiveWatchSimulator() async throws {
        guard let raw=ProcessInfo.processInfo.environment["WATCH_SIM_PORT"],let port=UInt16(raw) else {throw XCTSkip("Run tools/check_watch_channel.py for the live Rust simulator")}
        let ch=SimChannel(port:port);defer {ch.close()}
        let map=try WatchSnapshot(x:100000,y:100000,metersPerPixel:4,label:"Integration map",segments:[WatchSegment(x1:-500,y1:-300,x2:0,y2:200,kind:1),WatchSegment(x1:0,y1:200,x2:500,y2:-300,kind:2)])
        try await sendSnapshot(map,over:ch,id:123) {_ in}
        try await ch.send(phoneFix(x:100000,y:100000,accuracy:5))
        try await Task.sleep(for:.milliseconds(300))
        try await ch.send(phoneLocation(x:100000,y:100000,accuracy:5,epoch:1_800_000_000,age:90,live:false))
        try await ch.send(Data([84,77,1,5]))
        var viewport:WatchViewport?
        let until=ContinuousClock.now + .seconds(8)
        // Cold launch announces its initial camera before this test sends data.
        // Consume that announcement and wait for the actual drag request.
        while viewport==nil && ContinuousClock.now<until {
            if let candidate=WatchViewport(message:try await ch.recv(timeout:until-ContinuousClock.now)),candidate.scale==4 {viewport=candidate}
        }
        let v=try XCTUnwrap(viewport)
        XCTAssertEqual(v.scale,4);XCTAssertEqual(v.x,-13330400);XCTAssertEqual(v.y,-4490120)
        let detail=try WatchSnapshot(x:v.x,y:v.y,metersPerPixel:v.scale,label:"Refreshed detail",segments:[WatchSegment(x1:-500,y1:0,x2:500,y2:0,kind:1)])
        try await sendSnapshot(detail,over:ch,id:124) {_ in}
        var pixels=[UInt8](repeating:1,count:WatchRaster.width*WatchRaster.height)
        for y in 40..<170 {for x in 30..<200 {pixels[y*WatchRaster.width+x]=2}}
        for x in 20..<420 {pixels[120*WatchRaster.width+x]=7}
        let artwork=try WatchRaster(x:v.x,y:v.y,scale:v.scale,pixels:pixels)
        try await sendRaster(artwork,over:ch,id:125,checkpoint:{
            try await ch.send(phoneLocation(x:v.x,y:v.y,accuracy:5,epoch:1_800_000_000,age:0,live:true));return true
        })
        let places=(0..<32).map{WatchPlace(x:v.x+80+Int32($0*10),y:v.y,name:"Public test camp \($0)")}
        let saved=try await syncWatchPlaces(places,over:ch);XCTAssertEqual(saved,32)
        let unchanged=try await syncWatchPlaces(places,over:ch);XCTAssertEqual(unchanged,32)
    }
    func testStaleFixInvalidationPayload() {XCTAssertEqual(phoneFix(x:0,y:0,accuracy:1001),Data([84,77,1,5]))}
}

extension TransferTests {
    func testCachedFixAndUnknownSatellitesWireFormat() {
        let d=phoneLocation(x:100,y:-200,accuracy:5,epoch:1_800_000_000,age:90,live:false)
        XCTAssertEqual(d.count,24);XCTAssertEqual(Array(d.prefix(4)),[84,77,1,6]);XCTAssertEqual(d[14],0);XCTAssertEqual(d[15],255)
        let live=phoneLocation(x:100,y:-200,accuracy:5,epoch:1_800_000_000,age:0,live:true,satellites:8)
        XCTAssertEqual(live[14],1);XCTAssertEqual(live[15],8)
        XCTAssertEqual(phoneLocation(x:0,y:0,accuracy:5,epoch:0,age:15,live:true)[14],0)
        XCTAssertEqual(phoneLocation(x:0,y:0,accuracy:5,epoch:0,age:0,live:true,satellites:101),Data([84,77,1,5]))
    }
    func testMapSyncDoesNotRepeatUnchangedAreaOrFloodBLE() {
        XCTAssertTrue(WatchMapSyncPolicy.shouldSend(changed:true,running:true,sinceSuccess:nil,sinceAttempt:nil))
        XCTAssertFalse(WatchMapSyncPolicy.shouldSend(changed:false,running:true,sinceSuccess:100,sinceAttempt:100))
        XCTAssertFalse(WatchMapSyncPolicy.shouldSend(changed:true,running:false,sinceSuccess:100,sinceAttempt:100))
        XCTAssertFalse(WatchMapSyncPolicy.shouldSend(changed:true,running:true,sinceSuccess:9,sinceAttempt:100))
        XCTAssertFalse(WatchMapSyncPolicy.shouldSend(changed:true,running:true,sinceSuccess:100,sinceAttempt:14))
    }
    func testStoredColorSnapshotRoundTripAndBounds() throws {
        let s=try WatchSnapshot(x:0,y:0,metersPerPixel:8,label:"Test",segments:[WatchSegment(x1:0,y1:0,x2:10,y2:10,kind:3),WatchSegment(x1:0,y1:0,x2:10,y2:10,kind:4)])
        XCTAssertEqual(try WatchSnapshot(data:s.data).data,s.data)
        let padded=Data([0,0])+s.data;XCTAssertEqual(try WatchSnapshot(data:padded.dropFirst(2)).data,s.data)
        var bad=s.data;bad[56]=5;XCTAssertThrowsError(try WatchSnapshot(data:bad))
        XCTAssertThrowsError(try WatchSnapshot(data:Data(s.data.dropLast())))
    }
}

extension TransferTests {
    func testNationalViewportAndNormalizedVectorFallback() throws {
        let s=try WatchSnapshot(x:-14100000,y:-6500000,metersPerPixel:40000,label:"United States",segments:[],screenCoordinates:true)
        XCTAssertEqual(s.data.prefix(4),Data("TM02".utf8));XCTAssertEqual(try WatchSnapshot(data:s.data).scale,40000)
        let d=Data([84,77,1,17,0,0,0,0,0,0,0,0,64,156])
        XCTAssertEqual(WatchViewport(message:d)?.scale,40000)
    }
    func testNativeArtworkRoundTripAndPacketBounds() throws {
        var pixels=[UInt8](repeating:1,count:450*257)
        for i in 100..<2000 {pixels[i]=UInt8(i%14)}
        let raster=try WatchRaster(x:0,y:0,scale:8,pixels:pixels)
        var decoded=[UInt8](),i=1;let d=Array(raster.data)
        while i<d.count {let v=d[i];i+=1;if v>>4==15 {let pairs=Int(v&15)+1;for _ in 0..<pairs {decoded.append(d[i]>>4);decoded.append(d[i]&15);i+=1}}else{var n=Int(v&15)+1;if n==16 {n+=Int(d[i]);i+=1};decoded.append(contentsOf:repeatElement(v>>4,count:n))}}
        XCTAssertEqual(decoded,pixels)
        XCTAssertLessThan(raster.data.count,32768);XCTAssertTrue(raster.messages(id:80).allSatisfy{$0.count<=128})
        XCTAssertThrowsError(try WatchRaster(x:0,y:0,scale:8,pixels:[1]))
        pixels[0]=15;XCTAssertThrowsError(try WatchRaster(x:0,y:0,scale:8,pixels:pixels))
    }
}
extension TransferTests {
    func testDenseArtworkHasBoundedPixelPreservingFallback() throws {
        let colors:[UInt8]=[1,5,7,9]
        let pixels=(0..<450*257).map{colors[$0%4]}
        let raster=try WatchRaster(x:0,y:0,scale:8,pixels:pixels)
        let d=Array(raster.data)
        XCTAssertEqual(d[0],1);XCTAssertLessThanOrEqual(d.count,32768)
        let decoded=pixels.indices.map{i in d[1+Int((d[5+i/4]>>(6-2*(i%4)))&3)]}
        XCTAssertEqual(decoded,pixels)
    }
}

private actor RasterChannel:Channel {
    var packets=[Data](),inbox=[Data]()
    func send(_ data:Data) async throws {
        packets.append(data)
        if [0x20,0x22].contains(data[3]) {inbox.append(Data([84,77,1,128,data[4],data[5],0]))}
    }
    func recv(timeout:Duration) async throws ->Data {
        guard !inbox.isEmpty else{throw WireError.timeout("empty")};return inbox.removeFirst()
    }
    func committed(_ id:UInt8)->Bool {packets.contains{Array($0.prefix(6))==[84,77,1,0x22,id,0]}}
    func count()->Int {packets.count}
}
private actor Checkpoints {
    var calls=0
    func next()->Bool {calls+=1;return calls<2}
}
extension TransferTests {
    func testObsoleteArtworkStopsBeforeCommitAndReplacementCompletes() async throws {
        let channel=RasterChannel(),checks=Checkpoints()
        let raster=try WatchRaster(x:0,y:0,scale:8,pixels:[UInt8](repeating:1,count:450*257))
        let first=try await sendRaster(raster,over:channel,id:1,checkpoint:{await checks.next()})
        XCTAssertFalse(first)
        let committed=await channel.committed(1),sent=await channel.count()
        XCTAssertFalse(committed);XCTAssertEqual(sent,8)
        let second=try await sendRaster(raster,over:channel,id:2)
        XCTAssertTrue(second)
        let replacement=await channel.committed(2);XCTAssertTrue(replacement)
    }
}

extension TransferTests {
    func testSavedImageNoticeSkipsOnlyMatchingCameraAndContent() throws {
        let image=try WatchRaster(x:100,y:-200,scale:12,pixels:[UInt8](repeating:1,count:450*257))
        var d=Data([84,77,1,0x12]);for value in [UInt32(bitPattern:image.x),UInt32(bitPattern:image.y)] {withUnsafeBytes(of:value.littleEndian){d.append(contentsOf:$0)}}
        withUnsafeBytes(of:image.scale.littleEndian){d.append(contentsOf:$0)};withUnsafeBytes(of:WireKit.crc32(image.data).littleEndian){d.append(contentsOf:$0)}
        XCTAssertTrue(try XCTUnwrap(WatchCachedMap(message:d)).matches(image));d[14]^=1;XCTAssertFalse(try XCTUnwrap(WatchCachedMap(message:d)).matches(image));d[4]^=1;XCTAssertFalse(try XCTUnwrap(WatchCachedMap(message:d)).matches(image));XCTAssertNil(WatchCachedMap(message:d.dropLast()))
        XCTAssertEqual(WatchMapCacheStatus(message:Data([84,77,1,20,1,8,8,3,0,9,0]))?.count,8)
        XCTAssertNil(WatchMapCacheStatus(message:Data([84,77,1,20,1,9,8,0,0,0,0])))
    }
}
