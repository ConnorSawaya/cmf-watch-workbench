import Foundation
import WireKit
import XCTest

@testable import CompanionCore

#if canImport(Darwin)
  import Darwin

  private final class FaceSocket: Link, @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var callback: (@Sendable (String, Data) -> Void)?
    private var pending = [Int: CheckedContinuation<Void, Error>]()
    private var serial = 0
    init(port: UInt16) throws {
      fd = socket(AF_INET, SOCK_STREAM, 0)
      guard fd >= 0 else { throw WireError.closed }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      let rc = withUnsafePointer(to: &address) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard rc == 0 else {
        Darwin.close(fd)
        throw WireError.closed
      }
      DispatchQueue.global().async { self.readLoop() }
    }
    func onNotify(_ handler: @escaping @Sendable (String, Data) -> Void) {
      lock.withLock { callback = handler }
    }
    func write(_ uuid: String, _ data: Data) async throws {
      try await send(uuid, data, response: true)
    }
    func writeWithoutResponse(_ uuid: String, _ data: Data) async throws {
      try await send(uuid, data, response: false)
    }
    private func send(_ uuid: String, _ data: Data, response: Bool) async throws {
      try await withCheckedThrowingContinuation { c in
        lock.withLock {
          serial += 1
          let id = serial
          pending[id] = c
          guard
            let json = try? JSONSerialization.data(withJSONObject: [
              "id": id, "uuid": uuid, "data": data.map { String(format: "%02x", $0) }.joined(),
              "response": response,
            ])
          else {
            pending.removeValue(forKey: id)?.resume(throwing: WireError.closed)
            return
          }
          let line = Array(json + Data([10]))
          var sent = 0
          while sent < line.count {
            let n = line.withUnsafeBytes {
              Darwin.send(fd, $0.baseAddress! + sent, line.count - sent, 0)
            }
            if n <= 0 {
              pending.removeValue(forKey: id)?.resume(throwing: WireError.closed)
              return
            }
            sent += n
          }
        }
      }
    }
    private func readLoop() {
      var line = Data()
      var byte: UInt8 = 0
      while Darwin.recv(fd, &byte, 1, 0) == 1 {
        if byte != 10 {
          line.append(byte)
          if line.count > 65536 { break }
          continue
        }
        defer { line = Data() }
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
          break
        }
        if let id = json["id"] as? Int {
          let c = lock.withLock { pending.removeValue(forKey: id) }
          if json["ok"] as? Bool == true {
            c?.resume()
          } else {
            c?.resume(throwing: WireError.closed)
          }
        } else if let uuid = json["uuid"] as? String, let hex = json["data"] as? String {
          var data = Data()
          var p = hex.startIndex
          while p < hex.endIndex {
            let end = hex.index(p, offsetBy: 2)
            guard let b = UInt8(hex[p..<end], radix: 16) else { return }
            data.append(b)
            p = end
          }
          let handler = lock.withLock { callback }
          handler?(uuid, data)
        }
      }
      let all = lock.withLock {
        let p = pending
        pending = [:]
        return p
      }
      for c in all.values { c.resume(throwing: WireError.closed) }
    }
    func close() {
      shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
    }
  }
  final class LiveFaceTests: XCTestCase {
    func testUploadToVirtualWatch() async throws {
      let env = ProcessInfo.processInfo.environment
      guard let port = env["WATCH_FACE_TEST_PORT"].flatMap(UInt16.init),
        let path = env["WATCH_FACE_TEST_FILE"], let authHex = env["WATCH_FACE_TEST_AUTH"],
        let auth = channelKey(secretHex: authHex)
      else { throw XCTSkip("Run tools/verify_watch_faces.py for disposable ARM-guest coverage") }
      let face = try FaceFile(Data(contentsOf: URL(fileURLWithPath: path)))
      let link = try FaceSocket(port: port)
      defer { link.close() }
      let connection = StockConnection(link: link)
      await connection.attach()
      try await connection.resume(auth: auth)
      try await connection.initializeClock(
        epoch: UInt32(Date().timeIntervalSince1970), offsetMilliseconds: 0)
      if let reference = env["WATCH_FACE_DELETE_REFERENCE_ID"].flatMap(UInt32.init) {
        XCTAssertTrue((7..<10000).contains(reference))
        try await connection.uploadFace(face, id: reference, delete: true)
      }
      try await connection.uploadFace(face, id: 1_000_001)
      try Data("activated".utf8).write(to: URL(fileURLWithPath: env["WATCH_FACE_TEST_READY"]!))
      let deadline = ContinuousClock.now + .seconds(30)
      while !FileManager.default.fileExists(atPath: env["WATCH_FACE_TEST_ADVANCE"]!) {
        guard ContinuousClock.now < deadline else { throw WireError.timeout("clock observation") }
        try await Task.sleep(for: .milliseconds(100))
      }
      try await Task.sleep(for: .seconds(68))
      await connection.close()
    }
  }
#endif
