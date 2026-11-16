import Foundation

public enum WatchFaceError: LocalizedError {
  case invalidFile, unsupportedImage, tooComplex
  case rejected(UInt8)
  case notActivated, invalidRequest
  public var errorDescription: String? {
    switch self {
    case .invalidFile: "This is not a valid Watch Pro 2 watch-face file."
    case .unsupportedImage: "This face uses an unsupported image or an image larger than 466 × 466."
    case .tooComplex: "This face exceeds the supported size or image-memory budget."
    case .rejected(let code): "The watch rejected the face (code \(code))."
    case .notActivated:
      "The watch stored the file but did not activate the face. Free a face slot on the watch and retry. Existing faces were not removed."
    case .invalidRequest: "The watch requested invalid watch-face data. Installation was stopped."
    }
  }
}

public struct FaceImage: Sendable {
  public let width: Int, height: Int, format: Int, pixels: Data
  public init(width: Int, height: Int, format: Int, pixels: Data) throws {
    guard width > 0, height > 0, width <= 466, height <= 466 else {
      throw WatchFaceError.unsupportedImage
    }
    let size = try FaceFile.pixelBytes(width, height, format)
    guard pixels.count == size else { throw WatchFaceError.invalidFile }
    self.width = width
    self.height = height
    self.format = format
    self.pixels = pixels
  }
}

public enum FaceLZ4 {
  public static func encode(_ data: Data) -> Data {
    let b = Array(data)
    let n = b.count
    var out = [UInt8]()
    var table = [Int](repeating: -1, count: 65536)
    var anchor = 0
    var p = 0
    func hash(_ i: Int) -> Int {
      let v = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
      return Int((v &* 2_654_435_761) >> 16)
    }
    func extra(_ length: Int) {
      var r = length
      while r >= 255 {
        out.append(255)
        r -= 255
      }
      out.append(UInt8(r))
    }
    while p + 12 <= n {
      let h = hash(p)
      let q = table[h]
      table[h] = p
      if q < 0 || p - q > 65535 || b[q..<q + 4] != b[p..<p + 4] {
        p += 1
        continue
      }
      var end = p + 4
      while end < n - 5 && b[q + end - p] == b[end] { end += 1 }
      let literals = p - anchor
      let match = end - p - 4
      out.append(UInt8(min(15, literals) << 4 | min(15, match)))
      if literals >= 15 { extra(literals - 15) }
      out.append(contentsOf: b[anchor..<p])
      let distance = p - q
      out.append(UInt8(distance & 255))
      out.append(UInt8(distance >> 8))
      if match >= 15 { extra(match - 15) }
      p = end
      anchor = end
    }
    let count = n - anchor
    out.append(UInt8(min(count, 15) << 4))
    if count >= 15 { extra(count - 15) }
    out.append(contentsOf: b[anchor..<n])
    return Data(out)
  }
  public static func decode(_ input: Data, size: Int) throws -> Data {
    guard size > 0, size <= 2_097_152 else { throw WatchFaceError.tooComplex }
    let b = Array(input)
    var p = 0
    var out = [UInt8]()
    out.reserveCapacity(size)
    func length(_ initial: Int) throws -> Int {
      var n = initial
      if n == 15 {
        while true {
          guard p < b.count else { throw WatchFaceError.invalidFile }
          let v = Int(b[p])
          p += 1
          n += v
          guard n <= size else { throw WatchFaceError.invalidFile }
          if v != 255 { break }
        }
      }
      return n
    }
    while p < b.count {
      let token = b[p]
      p += 1
      let literals = try length(Int(token >> 4))
      guard literals <= b.count - p, literals <= size - out.count else {
        throw WatchFaceError.invalidFile
      }
      out.append(contentsOf: b[p..<p + literals])
      p += literals
      if p == b.count {
        guard out.count == size else { throw WatchFaceError.invalidFile }
        return Data(out)
      }
      guard b.count - p >= 2 else { throw WatchFaceError.invalidFile }
      let distance = Int(b[p]) | Int(b[p + 1]) << 8
      p += 2
      let count = try length(Int(token & 15)) + 4
      guard distance > 0, distance <= out.count, count <= size - out.count else {
        throw WatchFaceError.invalidFile
      }
      for _ in 0..<count { out.append(out[out.count - distance]) }
    }
    throw WatchFaceError.invalidFile
  }
}

public struct FaceFile: Sendable {
  public static let maximumBytes = 1_500_000
  public let data: Data, name: String, decodedBytes: Int, images: [FaceImage]
  public let resourceOffsets: [Int]
  private let previewIndex: Int?
  public var crc: UInt32 { FaceFile.rawCRC(data) }
  private static let crcTable: [UInt32] = (0..<256).map { n in
    (0..<8).reduce(UInt32(n)) { c, _ in (c >> 1) ^ (c & 1 == 1 ? 0xEDB8_8320 : 0) }
  }
  public static func rawCRC(_ data: Data) -> UInt32 {
    var c = UInt32(0)
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 255)] ^ (c >> 8) }
    return c
  }
  static func u16(_ d: Data, _ p: Int) -> Int { Int(d[p]) | Int(d[p + 1]) << 8 }
  static func u32(_ d: Data, _ p: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(d[p + $1]) << (8 * $1) }
  }
  static func pixelBytes(_ w: Int, _ h: Int, _ format: Int) throws -> Int {
    switch format {
    case 4: return w * h * 2
    case 5: return w * h * 3
    case 13: return (w * h + 1) / 2
    case 14: return w * h
    default: throw WatchFaceError.unsupportedImage
    }
  }
  public init(_ input: Data) throws {
    let d = Data(input)
    guard d.count >= 78, d.count <= Self.maximumBytes else { throw WatchFaceError.tooComplex }
    guard Self.u32(d, 4) == 1, d[36] == 0x20, Data(d.prefix(36)) == Data(d.suffix(36)) else {
      throw WatchFaceError.invalidFile
    }
    let resourceStart = 39 + Self.u16(d, 37)
    let footer = d.count - 36
    guard resourceStart <= footer, Self.u32(d, 24) == footer,
      Self.u32(d, 28) == footer - resourceStart,
      Self.rawCRC(Data(d[4..<resourceStart])) == Self.u32(d, 0),
      Self.rawCRC(Data(d[resourceStart..<footer])) == Self.u32(d, 32)
    else { throw WatchFaceError.invalidFile }
    let nameBytes = Array(d[8..<23]).prefix { $0 != 0 }
    guard !nameBytes.isEmpty, let name = String(bytes: nameBytes, encoding: .utf8) else {
      throw WatchFaceError.invalidFile
    }
    var resources = [FaceImage]()
    var offsets = [Int]()
    var spans = [Int: Int]()
    var p = resourceStart
    var total = 0
    while p < footer {
      guard footer - p >= 8, resources.count < 256 else { throw WatchFaceError.tooComplex }
      let header = Self.u32(d, p)
      let size = Int(Self.u32(d, p + 4))
      let w = Int((header >> 10) & 2047)
      let h = Int((header >> 21) & 2047)
      let format = Int(header & 31)
      guard w > 0, h > 0, w <= 466, h <= 466 else { throw WatchFaceError.unsupportedImage }
      let expected = try Self.pixelBytes(w, h, format)
      total += expected
      guard total <= 2_097_152, size > 0, size <= footer - p - 8 else {
        throw WatchFaceError.tooComplex
      }
      let pixels = try FaceLZ4.decode(Data(d[p + 8..<p + 8 + size]), size: expected)
      offsets.append(p)
      spans[p] = size + 8
      resources.append(try FaceImage(width: w, height: h, format: format, pixels: pixels))
      p += size + 8
    }
    guard !resources.isEmpty, p == footer else { throw WatchFaceError.invalidFile }
    var nodes = 0
    var screens = Set<UInt8>()
    var previewOffset: Int?
    let containers: Set<UInt8> = [0x21, 0x22, 0x28, 0x30, 0x60]
    func refs(_ start: Int, _ end: Int) throws {
      guard end - start >= 7 else { throw WatchFaceError.invalidFile }
      let kind = d[start]
      let count = Self.u16(d, start + 1)
      guard count > 0, count <= 256 else { throw WatchFaceError.tooComplex }
      if kind == 1 {
        guard end - start == 3 + 4 * count else { throw WatchFaceError.invalidFile }
        for i in 0..<count {
          guard spans[Int(Self.u32(d, start + 3 + i * 4))] != nil else {
            throw WatchFaceError.invalidFile
          }
        }
      } else if kind == 0x61 || kind == 0x71 {
        guard end - start == 7 + 2 * count else { throw WatchFaceError.invalidFile }
        var at = Int(Self.u32(d, start + 3))
        for i in 0..<count {
          let n = Self.u16(d, start + 7 + i * 2)
          guard spans[at] == n else { throw WatchFaceError.invalidFile }
          at += n
        }
      } else {
        throw WatchFaceError.invalidFile
      }
    }
    func tree(_ start: Int, _ end: Int, _ depth: Int) throws {
      guard depth < 16 else { throw WatchFaceError.tooComplex }
      var at = start
      while at < end {
        guard end - at >= 3 else { throw WatchFaceError.invalidFile }
        let tag = d[at]
        let n = Self.u16(d, at + 1)
        at += 3
        let stop = at + n
        nodes += 1
        guard stop <= end, nodes <= 1024 else { throw WatchFaceError.tooComplex }
        if depth == 0 {
          guard [0x21, 0x22, 0x86].contains(tag) else { throw WatchFaceError.invalidFile }
          if tag != 0x86 {
            guard !screens.contains(tag) else { throw WatchFaceError.invalidFile }
            screens.insert(tag)
          }
        }
        if containers.contains(tag) {
          try tree(at, stop, depth + 1)
        } else if tag == 1 {
          guard n >= 25 else { throw WatchFaceError.invalidFile }
          let x = Int(Int16(bitPattern: UInt16(Self.u16(d, at))))
          let y = Int(Int16(bitPattern: UInt16(Self.u16(d, at + 2))))
          let w = Self.u16(d, at + 4)
          let h = Self.u16(d, at + 6)
          guard abs(x) <= 1024, abs(y) <= 1024, (1...466).contains(w), (1...466).contains(h),
            d[at + 13] < 142
          else { throw WatchFaceError.invalidFile }
          try refs(at + 18, stop)
        } else if tag == 8 {
          guard n >= 12 else { throw WatchFaceError.invalidFile }
          try refs(at + 5, stop)
          if previewOffset == nil { previewOffset = Int(Self.u32(d, at + 8)) }
        } else if tag == 0x40 {
          guard n == 1, (1...8).contains(d[at] & 0x7f) else { throw WatchFaceError.invalidFile }
        } else if tag == 0x86 {
          guard depth == 0, n == 64 else { throw WatchFaceError.invalidFile }
        } else {
          throw WatchFaceError.invalidFile
        }
        at = stop
      }
    }
    try tree(39, resourceStart, 0)
    guard screens.contains(0x21) else { throw WatchFaceError.invalidFile }
    self.data = d
    self.name = name
    decodedBytes = total
    images = resources
    resourceOffsets = offsets
    previewIndex = previewOffset.flatMap { offsets.firstIndex(of: $0) }
  }
  public var preview: FaceImage? { previewIndex.map { images[$0] } }
}

public enum FaceCompiler {
  private static func le(_ value: Int, _ bytes: Int) -> Data {
    Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
  }
  private static func node(_ tag: UInt8, _ data: Data) -> Data {
    Data([tag]) + le(data.count, 2) + data
  }
  public static func digital(
    name: String, background: FaceImage, digits: [FaceImage], smallDigits: [FaceImage],
    aodDigits: [FaceImage], colon: FaceImage, separator: FaceImage, aodColon: FaceImage,
    preview: FaceImage
  ) throws -> FaceFile {
    let clean = String(
      name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.filter {
        (32...126).contains($0.value)
      }.map(Character.init).prefix(14))
    guard !clean.isEmpty, digits.count == 10, smallDigits.count == 10, aodDigits.count == 10 else {
      throw WatchFaceError.invalidFile
    }
    guard background.width == 466, background.height == 466 else {
      throw WatchFaceError.invalidFile
    }
    for bank in [digits, smallDigits, aodDigits] {
      guard bank.allSatisfy({ $0.width == bank[0].width && $0.height == bank[0].height }) else {
        throw WatchFaceError.invalidFile
      }
    }
    let images =
      [background] + digits + [colon] + smallDigits + [separator] + aodDigits + [aodColon, preview]
    let blocks = images.map { image -> Data in
      let packed = FaceLZ4.encode(image.pixels)
      return le(image.format | (image.width << 10) | (image.height << 21), 4) + le(packed.count, 4)
        + packed
    }
    func makeTree(_ offsets: [Int]) -> Data {
      func imageRefs(_ indices: [Int]) -> Data {
        Data([1]) + le(indices.count, 2) + indices.reduce(Data()) { $0 + le(offsets[$1], 4) }
      }
      func widget(
        _ tag: UInt8, _ x: Int, _ y: Int, _ source: UInt8, _ indices: [Int], _ count: Int = 0
      ) -> Data {
        var meta = Data(count: 14)
        meta.replaceSubrange(0..<2, with: le(images[indices[0]].width, 2))
        meta.replaceSubrange(2..<4, with: le(images[indices[0]].height, 2))
        meta[4] = 1
        meta[9] = source
        let maximum = [1: 24, 11: 60, 22: 12, 23: 31, 36: 100][Int(source)] ?? 0
        meta.replaceSubrange(11..<14, with: le(maximum, 3))
        let st = node(1, le(x, 2) + le(y, 2) + meta + imageRefs(indices))
        return node(tag, st + (count > 0 ? node(0x40, Data([0x80 | UInt8(count)])) : Data()))
      }
      func clock(_ y: Int, _ first: Int, _ colonIndex: Int) -> Data {
        let width = 4 * images[first].width + images[colonIndex].width
        let x = (466 - width) / 2
        let bank = Array(first..<first + 10)
        return widget(0x60, x, y, 1, bank, 2)
          + widget(0x30, x + 2 * images[first].width, y, 0, [colonIndex])
          + widget(0x60, x + 2 * images[first].width + images[colonIndex].width, y, 0x0b, bank, 2)
      }
      let small = Array(12..<22)
      let sx = (466 - 4 * smallDigits[0].width - separator.width) / 2
      let date =
        widget(0x60, sx, 290, 0x16, small, 2)
        + widget(0x30, sx + smallDigits[0].width * 2, 290, 0, [22])
        + widget(0x60, sx + smallDigits[0].width * 2 + separator.width, 290, 0x17, small, 2)
      let battery = widget(0x60, (466 - smallDigits[0].width * 3) / 2, 355, 0x24, small, 3)
      let previewNode = node(0x28, node(8, Data(count: 5) + imageRefs([images.count - 1])))
      let main = node(
        0x21, widget(0x30, 0, 0, 0, [0]) + clock(160, 1, 11) + date + battery + previewNode)
      let aod = node(0x22, clock(205, 23, 33))
      var title = Data(clean.utf8)
      title.append(Data(count: 64 - title.count))
      return node(0x20, main + aod + node(0x86, title))
    }
    let empty = makeTree([Int](repeating: 0, count: images.count))
    var offsets = [Int]()
    var at = 36 + empty.count
    for block in blocks {
      offsets.append(at)
      at += block.count
    }
    let tree = makeTree(offsets)
    let resourceData = blocks.reduce(Data(), +)
    var header = Data(count: 36)
    header.replaceSubrange(4..<8, with: le(1, 4))
    header.replaceSubrange(8..<8 + clean.utf8.count, with: Data(clean.utf8))
    header.replaceSubrange(24..<28, with: le(36 + tree.count + resourceData.count, 4))
    header.replaceSubrange(28..<32, with: le(resourceData.count, 4))
    header.replaceSubrange(32..<36, with: le(Int(FaceFile.rawCRC(resourceData)), 4))
    header.replaceSubrange(
      0..<4, with: le(Int(FaceFile.rawCRC(Data(header.dropFirst(4)) + tree)), 4))
    return try FaceFile(header + tree + resourceData + header)
  }
}
