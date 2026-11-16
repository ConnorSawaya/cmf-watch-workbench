import Foundation
import WireKit

public enum TransferError: LocalizedError {
  case invalidPackage, noAcknowledgement
  public var errorDescription: String? {
    switch self {
    case .invalidPackage: "The file is not a valid Watch Pro 2 app package."
    case .noAcknowledgement: "The watch did not confirm the app installation."
    }
  }
}
private func u32(_ d: Data, _ p: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(d[p + $1]) << (8 * $1) }
}
private func u16(_ d: Data, _ p: Int) -> UInt16 { UInt16(d[p]) | UInt16(d[p + 1]) << 8 }
public struct ValidatedPackage: Sendable {
  public let data: Data
  public let header: PackageHeader
  public let imageBytes: Int
  public init(_ data: Data) throws {
    let d = Data(data)
    guard d.count >= 64, d.count <= 262208, d.prefix(4) == Data("WP2A".utf8), u16(d, 4) == 1,
      d[6] <= 1, d[7] <= 3,
      d[56..<64].allSatisfy({ $0 == 0 }), u32(d, 52) == WireKit.crc32(Data(d.prefix(52)))
    else { throw TransferError.invalidPackage }
    let size = Int(u32(d, 36))
    let count = Int(u32(d, 44))
    let entry = Int(u32(d, 40))
    guard size > 0, size <= (d[6] == 0 ? 131072 : 65536), entry < size, entry % 2 == 0,
      count <= size / 4, d.count == 64 + size + 4 * count,
      u32(d, 48) == WireKit.crc32(Data(d.dropFirst(64))), let h = WireKit.parseHeader(d),
      !h.name.isEmpty,
      h.name.utf8.count <= 23,
      h.name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { throw TransferError.invalidPackage }
    var previous = -1
    for i in 0..<count {
      let off = Int(u32(d, 64 + size + 4 * i))
      guard off > previous, off <= size - 4 else { throw TransferError.invalidPackage }
      previous = off
    }
    self.data = d
    header = h
    imageBytes = size
  }
}
