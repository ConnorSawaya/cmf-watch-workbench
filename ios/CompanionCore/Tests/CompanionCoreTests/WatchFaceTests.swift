import WireKit
import XCTest

@testable import CompanionCore

func testFace() throws -> FaceFile {
  func image(_ w: Int, _ h: Int, _ value: UInt8) throws -> FaceImage {
    try FaceImage(width: w, height: h, format: 4, pixels: Data(repeating: value, count: w * h * 2))
  }
  return try FaceCompiler.digital(
    name: "Test clock", background: image(466, 466, 0),
    digits: (0..<10).map { try image(58, 104, UInt8($0)) },
    smallDigits: (0..<10).map { try image(18, 32, UInt8($0)) },
    aodDigits: (0..<10).map { try image(32, 56, UInt8($0)) }, colon: image(20, 104, 1),
    separator: image(12, 32, 1), aodColon: image(12, 56, 1), preview: image(120, 120, 0))
}
private actor FaceProgress {
  var values = [Int]()
  func add(_ n: Int) { values.append(n) }
}
private actor FacePeer {
  let base: MockStockState
  var size = 0, part = Data(), served = Data(), finished = false, old: UInt32 = 0, new: UInt32 = 0
  let invalid: Bool, status: UInt8
  init(base: MockStockState, invalid: Bool, status: UInt8) {
    self.base = base
    self.invalid = invalid
    self.status = status
  }
  func packet(_ command: UInt16, _ payload: Data) async -> Data {
    WireKit.frame(c2: command, payload: payload, key: await base.key)
  }
  func request(_ offset: Int, _ length: Int) async -> Data {
    var d = Data()
    for n in [offset, length] {
      for shift in [24, 16, 8, 0] { d.append(UInt8(truncatingIfNeeded: n >> shift)) }
    }
    d.append(0)
    return await packet(0xa064, d)
  }
  func write(_ d: Data) async throws -> Data? {
    let cmd = UInt16(d[9]) << 8 | UInt16(d[10])
    let body = Data(d.dropFirst(11))
    guard let key = await base.key else { throw WireError.closed }
    switch cmd {
    case 0x8052: return await packet(0x52, Data([1]))
    case 0x9075:
      let b = WireKit.open(key, body)!
      func word(_ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[p + $1]) << (8 * $1) } }
      old = word(1)
      new = word(5)
      size = Int(word(9))
      served = Data(count: size)
      return await packet(0xa075, Data([1])) + request(invalid ? size : 0, invalid ? 1 : size)
    case 0x9064:
      let bytes = Data(body.dropLast(4))
      XCTAssertEqual(
        WireKit.crc32(bytes),
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(body[body.count - 4 + $1]) << (8 * $1) })
      part.append(bytes)
      if Int(d[7]) << 8 | Int(d[8]) == Int(d[5]) << 8 | Int(d[6]) {
        served = part
        return await packet(0xa065, Data([status]))
      }
      return nil
    case 0x9065:
      finished = true
      return nil
    default: throw WireError.closed
    }
  }
}
private final class FaceTestLink: Link, @unchecked Sendable {
  let base = MockStockLink(), peer: FacePeer
  private let lock = NSLock()
  private var callback: (@Sendable (String, Data) -> Void)?
  private(set) var channels = [String]()
  init(invalid: Bool = false, status: UInt8 = 1) {
    peer = FacePeer(base: base.state, invalid: invalid, status: status)
  }
  func onNotify(_ handler: @escaping @Sendable (String, Data) -> Void) {
    lock.withLock { callback = handler }
    base.onNotify(handler)
  }
  func write(_ uuid: String, _ data: Data) async throws {
    XCTAssertNotEqual(uuid, StockConnection.faceWrite)
    try await base.write(uuid, data)
  }
  func writeWithoutResponse(_ uuid: String, _ data: Data) async throws {
    XCTAssertEqual(uuid, StockConnection.faceWrite)
    lock.withLock { channels.append(uuid) }
    if let reply = try await peer.write(data) {
      let cb = lock.withLock { callback }
      let channel = "02F00000-0000-0000-0000-00000000FFE2"
      // Unsolicited command-channel traffic can arrive between two fragments
      // of a face reply. Each characteristic must retain its own frame parser.
      cb?(channel, Data(reply.prefix(5)))
      cb?(Uuid.cmdNotify, WireKit.frame(c2: 0x0006, payload: Data([1]), key: await base.state.key))
      cb?(channel, Data(reply.dropFirst(5)))
    }
  }
}
final class WatchFaceTests: XCTestCase {
  func testCompressionRoundTripsAndRejectsInvalidReferences() throws {
    for n in [1, 4, 12, 13, 16, 100, 4096] {
      let data = Data((0..<n).map { UInt8(truncatingIfNeeded: $0 * 71) })
      XCTAssertEqual(try FaceLZ4.decode(FaceLZ4.encode(data), size: n), data)
      let solid = Data(repeating: 0, count: n)
      XCTAssertEqual(try FaceLZ4.decode(FaceLZ4.encode(solid), size: n), solid)
    }
    XCTAssertThrowsError(try FaceLZ4.decode(Data([0, 0, 0]), size: 10))
    let face = try testFace()
    XCTAssertEqual(face.images.count, 35)
    XCTAssertEqual(face.preview?.width, 120)
    XCTAssertLessThan(face.data.count, 20000)
    var bad = face.data
    bad[bad.count - 1] ^= 1
    XCTAssertThrowsError(try FaceFile(bad))
    bad = face.data
    bad[69] = 0
    bad[70] = 0
    bad[71] = 0
    bad[72] = 0
    let end = 39 + Int(bad[37]) + Int(bad[38]) * 256
    let c = FaceFile.rawCRC(Data(bad[4..<end]))
    for i in 0..<4 { bad[i] = UInt8(truncatingIfNeeded: c >> (8 * i)) }
    bad.replaceSubrange(bad.count - 36..<bad.count, with: Data(bad.prefix(36)))
    XCTAssertThrowsError(try FaceFile(bad))
  }
  func testImportUsesPreviewReferenceInsteadOfLastResource() throws {
    let face = try testFace()
    var bytes = face.data
    let treeEnd = 39 + FaceFile.u16(bytes, 37)
    func preview(_ start: Int, _ end: Int) -> Int? {
      var p = start
      while p < end {
        let tag = bytes[p]
        let stop = p + 3 + FaceFile.u16(bytes, p + 1)
        if tag == 8 { return p + 11 }
        if [0x21, 0x22, 0x28].contains(tag), let found = preview(p + 3, stop) { return found }
        p = stop
      }
      return nil
    }
    let pointer = try XCTUnwrap(preview(39, treeEnd))
    let offset = try XCTUnwrap(face.resourceOffsets.first)
    for i in 0..<4 { bytes[pointer + i] = UInt8(truncatingIfNeeded: offset >> (8 * i)) }
    let crc = FaceFile.rawCRC(Data(bytes[4..<treeEnd]))
    for i in 0..<4 { bytes[i] = UInt8(truncatingIfNeeded: crc >> (8 * i)) }
    bytes.replaceSubrange(bytes.count - 36..<bytes.count, with: Data(bytes.prefix(36)))
    XCTAssertEqual(try FaceFile(bytes).preview?.width, 466)
  }
  func testFaceUsesOnlyFaceChannelAndWaitsForActivation() async throws {
    let link = FaceTestLink()
    let s = StockConnection(link: link)
    await s.attach()
    _ = try await s.pair()
    let face = try testFace()
    let progress = FaceProgress()
    try await s.uploadFace(face, id: 12345, progress: { await progress.add($0) })
    let bytes = await link.peer.served
    XCTAssertEqual(bytes, face.data)
    let finished = await link.peer.finished
    XCTAssertTrue(finished)
    let values = await progress.values
    XCTAssertEqual(values.last, face.data.count)
    XCTAssertTrue(values.allSatisfy { $0 <= face.data.count })
    await s.close()
  }
  func testFullSlotsNeverBecomeAnInstalledFace() async throws {
    let link = FaceTestLink(status: 10)
    let s = StockConnection(link: link)
    await s.attach()
    _ = try await s.pair()
    do {
      try await s.uploadFace(testFace(), id: 12345)
      XCTFail("Stored-only reply was treated as active")
    } catch WatchFaceError.notActivated {}
    let finished = await link.peer.finished
    XCTAssertTrue(finished, "The finish acknowledgement is mandatory even on a refused activation")
    await s.close()
  }
  func testInvalidPullDoesNotSendFileData() async throws {
    let link = FaceTestLink(invalid: true)
    let s = StockConnection(link: link)
    await s.attach()
    _ = try await s.pair()
    do {
      try await s.uploadFace(testFace(), id: 12345)
      XCTFail("Invalid pull accepted")
    } catch WatchFaceError.invalidRequest {}
    let bytes = await link.peer.part
    XCTAssertTrue(bytes.isEmpty)
    await s.close()
  }
}
