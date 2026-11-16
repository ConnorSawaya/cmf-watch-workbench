import Foundation
import WireKit
import zlib

/// A complete, bounded WP2MAP1 file. Every compressed page and geometry is checked.
public struct WatchMapFile: Sendable {
    public let data: Data
    public let trailSegments: UInt32
    public let crc: UInt32
    public let codec: UInt32
    public init(_ input: Data) throws {
        let d=Data(input)
        func fail() -> TransferError { .invalidMap }
        func word(_ p:Int)->UInt32 {(0..<4).reduce(0){$0|UInt32(d[p+$1])<<(8*$1)}}
        func half(_ p:Int)->Int {Int(d[p])|Int(d[p+1])<<8}
        guard (64...9_200_000).contains(d.count),d.prefix(8)==Data("WP2MAP1\0".utf8),word(8)==1,word(12)==d.count,
              WireKit.crc32(Data(d.prefix(60)))==word(60),word(48)==8192,[1,2].contains(word(52)),[4,8,16].contains(word(44)) else {throw fail()}
        let width=half(24),height=half(26),names=Int(word(28)),count=Int(word(32)),start=Int(word(36)),grid=Int(word(44))
        guard width>0,height>0,count>0,count<=65535,names==64+width*height*8,start==names+count*32,start<d.count else {throw fail()}
        for byte in d[names..<start] where byte != 0 && !(32...126).contains(byte) {throw fail()}
        var spans=[Range<Int>]()
        for tile in 0..<width*height {
            let p=64+tile*8,offset=Int(word(p)),length=Int(word(p+4))
            if length==0 {guard offset==0 else{throw fail()};continue}
            guard offset>=start,offset<d.count,length<=d.count-offset else{throw fail()}
            spans.append(offset..<offset+length);var position=offset
            while position<offset+length {
                let pageHeader=word(52)==2 ? 20:8
                guard offset+length-position>=pageHeader else{throw fail()}
                let packed=half(position),rawCount=half(position+2),checksum=word(position+4)
                var pageBounds=[0,0,8192/grid,8192/grid]
                if pageHeader==20 {
                    pageBounds=(0..<4).map{half(position+8+$0*2)}
                    guard pageBounds[0]<=pageBounds[2],pageBounds[1]<=pageBounds[3],pageBounds[2]<=8192/grid,pageBounds[3]<=8192/grid,
                          half(position+16)>=1,half(position+18)>=half(position+16),half(position+18)<=60000 else{throw fail()}
                }
                position+=pageHeader
                guard packed>0,packed<=16512,rawCount>0,rawCount<=16384,packed<=offset+length-position else{throw fail()}
                var raw=Data(count:rawCount);var decoded=uLongf(rawCount)
                let result=raw.withUnsafeMutableBytes { out in d.withUnsafeBytes { src in
                    uncompress(out.bindMemory(to:Bytef.self).baseAddress!,&decoded,src.bindMemory(to:Bytef.self).baseAddress!+position,uLong(packed))
                }}
                guard result==Z_OK,decoded==rawCount,WireKit.crc32(raw)==checksum else{throw fail()}
                position+=packed;let b=Array(raw);var cursor=0
                while cursor<b.count {
                    guard b.count-cursor>=2 else{throw fail()}
                    let n=Int(b[cursor])|Int(b[cursor+1])<<8;cursor+=2
                    guard n>=10,n<=b.count-cursor else{throw fail()}
                    let end=cursor+n,name=Int(b[cursor+2])|Int(b[cursor+3])<<8
                    guard b[cursor]<=4,name<count,b[cursor+8]<=1 else{throw fail()}
                    var q=cursor+9
                    func uint() throws -> Int {
                        var value=0,shift=0
                        while q<end && shift<=28 {
                            let byte=Int(b[q]);q+=1
                            guard shift<28 || byte<=15 else{throw fail()}
                            value|=(byte&127)<<shift
                            if byte<128{return value};shift+=7
                        }
                        throw fail()
                    }
                    let parts=try uint();guard parts<=2048 else{throw fail()};var points=0
                    for _ in 0..<parts {
                        let n=try uint();points+=n;guard points<=2048 else{throw fail()};var x=0,y=0
                        for _ in 0..<n {
                            let dx=try uint(),dy=try uint();x+=(dx>>1) ^ -(dx&1);y+=(dy>>1) ^ -(dy&1)
                            guard (pageBounds[0]...pageBounds[2]).contains(x),(pageBounds[1]...pageBounds[3]).contains(y) else{throw fail()}
                        }
                    }
                    guard q==end else{throw fail()};cursor=end
                }
            }
        }
        spans.sort{$0.lowerBound<$1.lowerBound}
        guard spans.first?.lowerBound==start,spans.last?.upperBound==d.count else{throw fail()}
        for i in 1..<spans.count where spans[i-1].upperBound != spans[i].lowerBound {throw fail()}
        data=d;trailSegments=word(40);crc=WireKit.crc32(d);codec=word(52)
    }
}
