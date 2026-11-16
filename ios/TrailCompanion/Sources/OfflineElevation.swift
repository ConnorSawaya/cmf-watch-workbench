import Foundation
import zlib

struct TrailProfile {
    let length: Double
    let gain: Double
    let loss: Double
    let source: String
}
private struct ZipEntry {
    let compressed: Int
    let uncompressed: Int
    let offset: Int
    let method: Int
    let checksum: UInt32
}
final class OfflineElevation {
    private let data: Data
    private var entries=[String:ZipEntry]()
    private var cache=[String:[Int16]]()
    private let lock=NSLock()
    private let n=300
    init(url: URL) throws {
        data=try Data(contentsOf:url,options:.mappedIfSafe)
        let bytes=[UInt8](data)
        func u16(_ p:Int)->Int {Int(bytes[p]) | Int(bytes[p+1])<<8}
        func u32(_ p:Int)->Int {u16(p) | u16(p+2)<<16}
        guard bytes.count>=22 else {throw MapError.malformed}
        var eocd:Int?;var i=bytes.count-22
        while i>=max(0,bytes.count-65557) {
            if u32(i)==0x06054b50 && i+22+u16(i+20)==bytes.count {eocd=i;break};i-=1
        }
        guard let eocd else {throw MapError.malformed}
        let count=u16(eocd+10);var p=u32(eocd+16)
        for _ in 0..<count {
            guard p>=0,p+46<=bytes.count,u32(p)==0x02014b50 else {throw MapError.malformed}
            let method=u16(p+10),crc=UInt32(u32(p+16)),compressed=u32(p+20),uncompressed=u32(p+24)
            let nameLen=u16(p+28),extraLen=u16(p+30),commentLen=u16(p+32),offset=u32(p+42)
            guard p+46+nameLen+extraLen+commentLen<=bytes.count,
                  let name=String(bytes:bytes[p+46..<p+46+nameLen],encoding:.utf8) else {throw MapError.malformed}
            entries[name]=ZipEntry(compressed:compressed,uncompressed:uncompressed,offset:offset,method:method,checksum:crc)
            p+=46+nameLen+extraLen+commentLen
        }
    }
    private func bytesFor(_ name:String)throws->Data? {
        guard let e=entries[name] else{return nil}
        guard e.offset>=0,e.offset+30<=data.count else {throw MapError.malformed}
        let h=[UInt8](data[e.offset..<e.offset+30])
        guard h[0]==0x50,h[1]==0x4b,h[2]==0x03,h[3]==0x04 else {throw MapError.malformed}
        let nameLength=Int(h[26]) | Int(h[27])<<8,extraLength=Int(h[28]) | Int(h[29])<<8
        let start=e.offset+30+nameLength+extraLength
        guard e.uncompressed<=1024*1024,start>=0,start<=data.count,e.compressed<=data.count-start else {throw MapError.malformed}
        let source=data.subdata(in:start..<start+e.compressed)
        if e.method==0 {guard source.count==e.uncompressed else {throw MapError.malformed};return source}
        guard e.method==8 else {throw MapError.malformed}
        var stream=z_stream();guard inflateInit2_(&stream,-15,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw MapError.decompression}
        defer {inflateEnd(&stream)}
        var output=Data(count:e.uncompressed)
        let code:Int32=output.withUnsafeMutableBytes { dst in
            source.withUnsafeBytes { src in
                stream.next_in=UnsafeMutablePointer<Bytef>(mutating:src.bindMemory(to:Bytef.self).baseAddress)
                stream.avail_in=uInt(source.count);stream.next_out=dst.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(e.uncompressed)
                return inflate(&stream,Z_FINISH)
            }
        }
        guard code==Z_STREAM_END,stream.total_out==e.uncompressed else {throw MapError.decompression}
        let checksum=output.withUnsafeBytes { crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(output.count)) }
        guard UInt32(checksum)==e.checksum else {throw MapError.decompression}
        return output
    }
    private func tile(_ lat:Int,_ lon:Int)->[Int16]? {
        let name="\(lat)_\(lon).bin";lock.lock();defer{lock.unlock()}
        if let value=cache[name] {return value}
        guard let raw=try? bytesFor(name),raw.count==n*n*2 else {return nil}
        let bytes=[UInt8](raw);var values=[Int16]();values.reserveCapacity(n*n)
        for i in stride(from:0,to:bytes.count,by:2) {values.append(Int16(bitPattern:UInt16(bytes[i]) | UInt16(bytes[i+1])<<8))}
        if cache.count>=16 {cache.removeAll(keepingCapacity:true)}
        cache[name]=values;return values
    }
    private func floorDivide(_ a:Int,_ b:Int)->Int {let q=a/b;return a%b<0 ? q-1 : q}
    private func pixel(_ x:Int,_ y:Int)->Double? {
        let col=floorDivide(x,n),row=floorDivide(y,n),lat=89-row,lon=col-180
        guard let data=tile(lat,lon) else{return nil}
        let value=data[(y-row*n)*n+x-col*n]
        return value == Int16.min ? nil : Double(value)
    }
    func elevation(at point:MapPoint)->Double? {
        let r=6378137.0,lon=point.x/r*180/Double.pi,lat=atan(sinh(-point.y/r))*180/Double.pi
        guard lon >= -180 && lon < 180 && lat > -90 && lat <= 90 else{return nil}
        let gx=(lon+180)*Double(n)-0.5,gy=(90-lat)*Double(n)-0.5
        let x=Int(floor(gx)),y=Int(floor(gy)),fx=gx-Double(x),fy=gy-Double(y)
        guard let a=pixel(x,y),let b=pixel(x+1,y),let c=pixel(x,y+1),let d=pixel(x+1,y+1) else{return nil}
        return a*(1-fx)*(1-fy)+b*fx*(1-fy)+c*(1-fx)*fy+d*fx*fy
    }
    func gain(_ points:[MapPoint])->Double? {
        guard points.count>=2 else{return nil};var heights=[Double]()
        for i in 1..<points.count {
            let a=points[i-1],b=points[i],dist=OfflineRouter.distance(a,b),steps=max(1,Int(ceil(dist/160)))
            for j in 0..<steps {let t=Double(j)/Double(steps);guard let h=elevation(at:MapPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)) else{return nil};heights.append(h)}
        }
        guard let end=elevation(at:points.last!),let first=heights.first else{return nil};heights.append(end)
        var low=first,high=first,gain=0.0,ascending=false
        for value in heights.dropFirst() {
            if ascending {high=max(high,value);if high-value>=5 {gain+=high-low;low=value;ascending=false}}
            else {low=min(low,value);if value-low>=5 {high=value;ascending=true}}
        }
        if ascending {gain+=high-low};return gain
    }
    func trailProfile(map:OfflineMap,place:SearchPlace)->TrailProfile? {
        let p=place.point,g=map.grid,bounds=[p.x-g,p.y-g,p.x+g,p.y+g]
        let features=map.visibleFeatures(bounds:bounds,scale:0.3,maxFeatures:40000)
        guard let feature=features.first(where:{$0.kind==0 && $0.name==place.name && $0.parts.first?.first==p}) else{return nil}
        var length=0.0,up=0.0,down=0.0,hasPart=false
        for part in feature.parts where part.count>=2 {
            guard let a=gain(part),let b=gain(Array(part.reversed())) else{return nil}
            up+=a;down+=b;hasPart=true
            for i in 1..<part.count {length+=OfflineRouter.distance(part[i-1],part[i])}
        }
        guard hasPart else{return nil}
        return TrailProfile(length:length,gain:up,loss:down,source:feature.flags & 8 != 0 ? "USGS" : "OpenStreetMap")
    }
}
