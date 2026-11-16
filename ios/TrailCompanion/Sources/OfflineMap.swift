import Foundation
import CoreGraphics
import zlib

struct MapPoint: Codable, Hashable {
    var x: Double
    var y: Double
}
struct SearchPlace: Codable, Hashable, Identifiable {
    var name: String
    var kind: String
    var point: MapPoint
    var id: String { "\(name)|\(kind)|\(point.x)|\(point.y)" }
}
struct StateShape {
    let name: String
    let abbreviation: String
    let center:MapPoint
    let polygons: [[[MapPoint]]]
    let path: CGPath
}
struct MapFeature {
    let kind: Int
    let subtype: String
    let flags: Int
    let name: String
    let parts: [[MapPoint]]
    let closed: Bool
    let path: CGPath
}

private func geometryPath(_ parts: [[MapPoint]], closed: Bool) -> CGPath {
    let path = CGMutablePath()
    for part in parts where !part.isEmpty {
        path.move(to: CGPoint(x: part[0].x, y: part[0].y))
        for point in part.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
        if closed { path.closeSubpath() }
    }
    return path.copy()!
}
struct MapChunk {
    let offset: Int
    let length: Int
    let cellX: Int
    let cellY: Int
    let zoom: Int
    let bounds: [Double]
}
struct SearchRecord {
    let nameIndex: Int
    let kind: Int
    let x: Int
    let y: Int
}
enum MapError: LocalizedError {
    case malformed, decompression
    var errorDescription: String? { self == .malformed ? "The offline map data is invalid." : "The offline map data could not be unpacked." }
}

func inflateZlib(_ data: Data, maxBytes: Int = 256 * 1024 * 1024) throws -> Data {
    var capacity = max(1024, data.count * 3)
    while capacity <= maxBytes {
        var output = Data(count: capacity)
        var length = uLongf(capacity)
        let result: Int32 = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                guard let dstBase = dst.bindMemory(to: Bytef.self).baseAddress,
                      let srcBase = src.bindMemory(to: Bytef.self).baseAddress else { return Z_DATA_ERROR }
                return uncompress(dstBase, &length, srcBase, uLong(data.count))
            }
        }
        if result == Z_OK { output.count = Int(length); return output }
        if result != Z_BUF_ERROR { throw MapError.decompression }
        capacity *= 2
    }
    throw MapError.decompression
}

struct ByteReader {
    let bytes: [UInt8]
    var position = 0
    mutating func byte() throws -> Int {
        guard position < bytes.count else { throw MapError.malformed }
        defer { position += 1 }
        return Int(bytes[position])
    }
    mutating func uint() throws -> Int {
        var value = 0, shift = 0
        while shift <= 56 {
            let b = try byte()
            value |= (b & 127) << shift
            if b < 128 { return value }
            shift += 7
        }
        throw MapError.malformed
    }
    mutating func integer() throws -> Int {
        let n = try uint()
        return n & 1 == 1 ? -(n / 2) - 1 : n / 2
    }
    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position <= bytes.count, count <= bytes.count-position else { throw MapError.malformed }
        let out = Array(bytes[position..<position+count]); position += count; return out
    }
}

private final class FeatureCacheBox:NSObject {
    let features:[MapFeature]
    init(_ features:[MapFeature]) {self.features=features}
}
final class OfflineMap {
    private let featureCache:NSCache<NSString,FeatureCacheBox> = {
        let c=NSCache<NSString,FeatureCacheBox>();c.totalCostLimit=24*1024*1024;c.countLimit=48;return c
    }()
    static let kinds = ["city", "town", "place", "trail", "road", "park", "water", "building", "waterway", "wood", "sand"]
    let data: Data
    let names: [String]
    let subtypes: [String]
    let states: [StateShape]
    let chunks: [MapChunk]
    let records: [SearchRecord]
    let grid: Double
    let cell: Double

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.data = data
        guard data.count >= 24, Array(data.prefix(8)) == Array("CMFMAP1\0".utf8) else { throw MapError.malformed }
        func little64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset+$1]) << (8*$1) }
        }
        let start = Int(little64(8)), length = Int(little64(16))
        guard start >= 24, length > 0, start <= data.count, length == data.count-start else { throw MapError.malformed }
        let raw = try inflateZlib(data.subdata(in: start..<start+length))
        guard let index = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let summary = index["summary"] as? [String: Any],
              let grid = summary["grid_metres"] as? Double,
              let cell = summary["cell_metres"] as? Double,
              let names = index["names"] as? [String], let subtypes = index["subtypes"] as? [String],
              let rows = index["chunks"] as? [[Double]],
              let statesObj = index["states"] as? [String: Any],
              let stateRows = statesObj["states"] as? [[String: Any]],
              let encoded = index["search_v1"] as? String,
              let compressed = Data(base64Encoded: encoded) else { throw MapError.malformed }
        self.grid=grid; self.cell=cell; self.names=names; self.subtypes=subtypes
        chunks = rows.compactMap { row in
            guard row.count >= 10 else { return nil }
            let offset=Int(row[0]), length=Int(row[1])
            guard offset>=24, length>0, offset <= start, length <= start-offset else { return nil }
            return MapChunk(offset:offset,length:length,cellX:Int(row[2]),cellY:Int(row[3]),zoom:Int(row[4]),bounds:Array(row[5...8]))
        }
        states = stateRows.compactMap { row in
            guard let name=row["name"] as? String, let abbr=row["abbr"] as? String,
                  let polygons=row["polygons"] as? [[[[Double]]]] else { return nil }
            let projected=polygons.map { $0.map { $0.compactMap { $0.count >= 2 ? MapPoint(x:$0[0],y:$0[1]) : nil } } }
            let path=geometryPath(projected.flatMap { $0 },closed:true)
            let value=row["center"] as? [Double]
            let center=value.flatMap{$0.count>=2 ? MapPoint(x:$0[0],y:$0[1]):nil} ?? MapPoint(x:path.boundingBoxOfPath.midX,y:path.boundingBoxOfPath.midY)
            return StateShape(name:name,abbreviation:abbr,center:center,polygons:projected,path:path)
        }
        var reader = ByteReader(bytes:Array(try inflateZlib(compressed)))
        var nameID=0, x=0, y=0, output=[SearchRecord]()
        output.reserveCapacity(600_000)
        while reader.position < reader.bytes.count {
            nameID += try reader.uint(); let kind=try reader.uint(); x += try reader.integer(); y += try reader.integer()
            guard nameID<names.count, kind<OfflineMap.kinds.count else { throw MapError.malformed }
            output.append(SearchRecord(nameIndex:nameID,kind:kind,x:x,y:y))
        }
        records=output
    }

    func search(_ text: String, near center: MapPoint) -> [SearchPlace] {
        let q = text.trimmingCharacters(in:.whitespacesAndNewlines).folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
        guard q.count>=2 else { return [] }
        var matching=Set<Int>()
        for (index,name) in names.enumerated() where name.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current).contains(q) { matching.insert(index) }
        var results=[(Int,Double,SearchPlace)]()
        for record in records where matching.contains(record.nameIndex) {
            let point=MapPoint(x:Double(record.x)*grid,y:Double(record.y)*grid)
            let normalized=names[record.nameIndex].folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
            let rank=normalized==q ? 0 : normalized.hasPrefix(q) ? 1 : 2
            results.append((rank,hypot(point.x-center.x,point.y-center.y),SearchPlace(name:names[record.nameIndex],kind:Self.kinds[record.kind],point:point)))
        }
        results.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        return results.prefix(300).map { $0.2 }
    }

    func visibleFeatures(bounds: [Double], scale: Double, roadsOnly: Bool = false, maxFeatures: Int = 40_000) -> [MapFeature] {
        let zoom = Int(floor(log2(156543.03392804097/scale)+0.15))
        guard zoom>=5 else { return [] }
        let matching=chunks.filter { $0.zoom<=zoom && $0.bounds[0]<=bounds[2] && $0.bounds[2]>=bounds[0] && $0.bounds[1]<=bounds[3] && $0.bounds[3]>=bounds[1] }
        var output=[MapFeature]()
        let viewport=CGRect(x:bounds[0],y:bounds[1],width:max(1,bounds[2]-bounds[0]),height:max(1,bounds[3]-bounds[1]))
        let lodScale=156543.03392804097/pow(2,Double(zoom))
        for chunk in matching {
            guard output.count < maxFeatures else { break }
            let key="\(chunk.offset)/\(zoom)/\(roadsOnly)" as NSString
            if let cached=featureCache.object(forKey:key) {
                output.append(contentsOf:cached.features.lazy.filter{$0.path.boundingBoxOfPath.intersects(viewport)}.prefix(maxFeatures-output.count));continue
            }
            do {
                var decoded=[MapFeature]()
                let bytes=try inflateZlib(data.subdata(in:chunk.offset..<chunk.offset+chunk.length),maxBytes:64*1024*1024)
                var reader=ByteReader(bytes:Array(bytes))
                let originX=Int((Double(chunk.cellX)*cell/grid).rounded()),originY=Int((Double(chunk.cellY)*cell/grid).rounded())
                while reader.position<reader.bytes.count && decoded.count<50000 {
                    let header=try reader.byte(),kind=header & 7,flags=header >> 3
                    let subtype=try reader.uint(),name=try reader.uint(),size=try reader.uint(),length=try reader.uint()
                    guard subtype<subtypes.count,name<names.count else { throw MapError.malformed }
                    let geometry=try reader.take(length)
                    if roadsOnly && (kind != 0 || flags & 9 != 0) { continue }
                    if ![0,2,7].contains(kind) && Double(size)<lodScale*lodScale*2 { continue }
                    if kind==2 && subtypes[subtype]=="stream" && zoom<13 { continue }
                    var geom=ByteReader(bytes:geometry),parts=[[MapPoint]](),closed=false
                    func sequence(_ reader: inout ByteReader) throws -> [MapPoint] {
                        let count=try reader.uint();guard count>0 && count<=reader.bytes.count/2 else { throw MapError.malformed }
                        var x=originX,y=originY,points=[MapPoint]();points.reserveCapacity(count)
                        for _ in 0..<count {x += try reader.integer();y += try reader.integer();points.append(MapPoint(x:Double(x)*grid,y:Double(y)*grid))}
                        return points
                    }
                    func readGeometry(_ reader: inout ByteReader) throws {
                        let type=try reader.byte()
                        if type==1 || type==2 { parts.append(try sequence(&reader)) }
                        else if type==3 { closed=true;let n=try reader.uint();guard n<=reader.bytes.count else {throw MapError.malformed};for _ in 0..<n {parts.append(try sequence(&reader))} }
                        else if (4...7).contains(type) {let n=try reader.uint();guard n<=reader.bytes.count else {throw MapError.malformed};for _ in 0..<n {try readGeometry(&reader)}}
                        else {throw MapError.malformed}
                    }
                    try readGeometry(&geom)
                    decoded.append(MapFeature(kind:kind,subtype:subtypes[subtype],flags:flags,name:names[name],parts:parts,closed:closed,path:geometryPath(parts,closed:closed)))
                }
                let cost=decoded.reduce(0){$0+128+$1.parts.reduce(0){$0+$1.count*16}}
                if reader.position==reader.bytes.count {featureCache.setObject(FeatureCacheBox(decoded),forKey:key,cost:cost)}
                output.append(contentsOf:decoded.lazy.filter{$0.path.boundingBoxOfPath.intersects(viewport)}.prefix(maxFeatures-output.count))
            } catch { continue }
        }
        return output
    }
}


struct MapDrawingLayer {
    let kind:Int
    let path:CGPath
    static func build(_ features:[MapFeature])->[MapDrawingLayer] {
        let paths=(0..<6).map{_ in CGMutablePath()}
        for f in features {
            let kind:Int
            if f.closed {kind=f.kind==4 ? 4:(f.kind==3 || f.kind==5 ? 3:5)}
            else if f.kind==0 {kind=["path","bridleway","via_ferrata"].contains(f.subtype) || (["footway","cycleway"].contains(f.subtype) && f.flags&2 != 0) ? 1:0}
            else if f.kind==2 {kind=2}else{continue}
            paths[kind].addPath(f.path)
        }
        return [5,3,4,0,1,2].compactMap{paths[$0].isEmpty ? nil:MapDrawingLayer(kind:$0,path:paths[$0].copy()!)}
    }
}
