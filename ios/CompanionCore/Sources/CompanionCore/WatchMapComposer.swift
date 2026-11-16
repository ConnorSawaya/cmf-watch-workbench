import Foundation

public struct WatchMapPoint:Sendable {
    public var x:Double,y:Double
    public init(x:Double,y:Double) {self.x=x;self.y=y}
}
public struct WatchMapLine:Sendable {
    public var points:[WatchMapPoint],kind:UInt8
    public init(points:[WatchMapPoint],kind:UInt8) {self.points=points;self.kind=kind}
}
/// Clip and simplify in screen space, then share the fixed transfer budget across the viewport.
public enum WatchMapComposer {
    public static func segments(lines:[WatchMapLine],center:WatchMapPoint,scale:Double,limit:Int=400)->[WatchSegment] {
        guard scale.isFinite,scale>=1,center.x.isFinite,center.y.isFinite else{return []}
        let radius=min(32760,scale*235),tolerance=scale*0.8
        struct Candidate {var segment:WatchSegment;var length:Double;var order:Int}
        var buckets=Array(repeating:[Candidate](),count:100),seen=Set<String>()
        func clip(_ a:WatchMapPoint,_ b:WatchMapPoint)->(WatchMapPoint,WatchMapPoint)? {
            let dx=b.x-a.x,dy=b.y-a.y
            var lo=0.0,hi=1.0
            for (p,q) in [(-dx,a.x+radius),(dx,radius-a.x),(-dy,a.y+radius),(dy,radius-a.y)] {
                if p==0 {if q<0 {return nil}} else {let t=q/p;if p<0 {lo=max(lo,t)}else{hi=min(hi,t)};if lo>hi {return nil}}
            }
            return (.init(x:a.x+lo*dx,y:a.y+lo*dy),.init(x:a.x+hi*dx,y:a.y+hi*dy))
        }
        func simplify(_ p:[WatchMapPoint])->[WatchMapPoint] {
            guard p.count>2 else{return p}
            var keep=Set([0,p.count-1]),stack=[(0,p.count-1)]
            while let (a,b)=stack.popLast(),b>a+1 {
                let dx=p[b].x-p[a].x,dy=p[b].y-p[a].y,l=dx*dx+dy*dy
                var best=tolerance*tolerance,index = -1
                for i in a+1..<b {
                    let t=l>0 ? max(0,min(1,((p[i].x-p[a].x)*dx+(p[i].y-p[a].y)*dy)/l)):0
                    let ex=p[i].x-p[a].x-t*dx,ey=p[i].y-p[a].y-t*dy,d=ex*ex+ey*ey
                    if d>best {best=d;index=i}
                }
                if index>=0 {keep.insert(index);stack.append((a,index));stack.append((index,b))}
            }
            return keep.sorted().map{p[$0]}
        }
        for (order,line) in lines.enumerated() where line.kind<=4 {
            guard line.points.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{continue}
            let points=line.points.map{WatchMapPoint(x:$0.x-center.x,y:$0.y-center.y)}
            guard points.count>1 else{continue}
            let simplified=simplify(points)
            for (a,b) in zip(simplified,simplified.dropFirst()) {
                guard let (a,b)=clip(a,b) else{continue}
                let length=hypot(b.x-a.x,b.y-a.y)/scale
                guard length>=0.75 else{continue}
                let v=[a.x,a.y,b.x,b.y].map{Int16($0.rounded())}
                let aa="\(Int((a.x/scale).rounded())),\(Int((a.y/scale).rounded()))",bb="\(Int((b.x/scale).rounded())),\(Int((b.y/scale).rounded()))"
                let key="\(line.kind):"+(aa<bb ? aa+":"+bb:bb+":"+aa)
                guard seen.insert(key).inserted else{continue}
                let x=max(0,min(9,Int(((a.x+b.x)/2+radius)/(2*radius)*10))),y=max(0,min(9,Int(((a.y+b.y)/2+radius)/(2*radius)*10)))
                buckets[y*10+x].append(Candidate(segment:.init(x1:v[0],y1:v[1],x2:v[2],y2:v[3],kind:line.kind),length:length,order:order))
            }
        }
        // Small features cannot consume a whole cell before its main roads and trails are represented.
        func rank(_ c:Candidate)->Double {let k=c.segment.kind;return (k==2 ? 10000:k==1 ? 1000:k==0 ? 200:0)+min(c.length,180)}
        for i in buckets.indices {buckets[i].sort{let a=rank($0),b=rank($1);return a==b ? $0.order<$1.order:a>b}}
        let cells=(0..<100).sorted{let a=hypot(Double($0%10)-4.5,Double($0/10)-4.5),b=hypot(Double($1%10)-4.5,Double($1/10)-4.5);return a==b ? $0<$1:a<b}
        let budget=max(0,min(400,limit))
        var out=[WatchSegment](),selected=Set<String>()
        func identity(_ s:WatchSegment)->String {"\(s.x1),\(s.y1),\(s.x2),\(s.y2),\(s.kind)"}
        func pick(_ kind:UInt8?,_ cap:Int) {
            let eligible=buckets.map{bucket in bucket.filter{kind == nil || $0.segment.kind==kind}}
            var offset=0,taken=0
            while out.count<budget && taken<cap {
                var any=false
                for cell in cells where eligible[cell].count>offset {
                    any=true;let segment=eligible[cell][offset].segment
                    if selected.insert(identity(segment)).inserted {out.append(segment);taken+=1}
                    if out.count==budget || taken==cap {return}
                }
                if !any {break};offset+=1
            }
        }
        pick(2,min(100,budget/3));pick(3,min(20,budget/16));pick(4,min(20,budget/16))
        pick(1,min(140,budget/2));pick(0,budget-out.count)
        pick(nil,budget-out.count)
        return out
    }
}
