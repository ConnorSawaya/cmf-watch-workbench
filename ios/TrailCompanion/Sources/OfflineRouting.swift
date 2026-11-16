import Foundation

struct WalkingRoute {
    let points: [MapPoint]
    let distance: Double
}
enum RouteFailure: LocalizedError {
    case tooFar, tooLarge, noNearby, disconnected
    var errorDescription: String? {
        switch self {
        case .tooFar: return "Walking routes are limited to about 10 miles in this preview."
        case .tooLarge: return "This area is too detailed to calculate a route."
        case .noNearby: return "The start or destination is too far from a mapped walking path."
        case .disconnected: return "No connected walking route was found."
        }
    }
}
private struct Edge { let node: Int; let length: Double }
private struct Snap {
    var squared: Double; var fraction: Double; var point: MapPoint
    var from: Int; var to: Int; var length: Double
}
private struct Heap {
    var values=[(Double,Int)]()
    mutating func push(_ item:(Double,Int)) {
        values.append(item);var i=values.count-1
        while i>0 {let p=(i-1)/2;if values[p].0<=item.0 {break};values[i]=values[p];i=p};values[i]=item
    }
    mutating func pop()->(Double,Int)? {
        guard !values.isEmpty else{return nil};let first=values[0],last=values.removeLast()
        if !values.isEmpty {var i=0;while i*2+1<values.count {var c=i*2+1;if c+1<values.count && values[c+1].0<values[c].0 {c+=1};if values[c].0>=last.0 {break};values[i]=values[c];i=c};values[i]=last}
        return first
    }
}
struct OfflineRouter {
    static let allowed=Set(["primary","secondary","tertiary","residential","unclassified","living_street","pedestrian","service","track","footway","path","cycleway","steps","bridleway","primary_link","secondary_link","tertiary_link"])
    static func distance(_ a:MapPoint,_ b:MapPoint)->Double {
        let r=6378137.0,earth=6371000.0
        let la=atan(sinh(-a.y/r)),lb=atan(sinh(-b.y/r)),dl=(b.x-a.x)/r
        let h=pow(sin((lb-la)/2),2)+cos(la)*cos(lb)*pow(sin(dl/2),2)
        return 2*earth*asin(min(1,sqrt(max(0,h))))
    }
    static func find(map:OfflineMap,start:MapPoint,end:MapPoint)throws->WalkingRoute {
        let direct=distance(start,end);guard direct<=16000 else {throw RouteFailure.tooFar}
        let lat=atan(sinh(-(start.y+end.y)/(2*6378137)))
        let pad=max(1400,min(3500,direct*0.35))/max(0.3,cos(lat))
        let bounds=[min(start.x,end.x)-pad,min(start.y,end.y)-pad,max(start.x,end.x)+pad,max(start.y,end.y)+pad]
        let features=map.visibleFeatures(bounds:bounds,scale:0.3,roadsOnly:true,maxFeatures:150_001)
        guard features.count<150_001 else {throw RouteFailure.tooLarge}
        var nodes=[MapPoint](),index=[MapPoint:Int](),graph=[[Edge]](),nearest=[Snap?](repeating:nil,count:2),segments=0
        func getNode(_ p:MapPoint)->Int {
            if let n=index[p] {return n};let n=nodes.count;nodes.append(p);index[p]=n;graph.append([]);return n
        }
        func connect(_ a:Int,_ b:Int,_ length:Double) {graph[a].append(Edge(node:b,length:length));graph[b].append(Edge(node:a,length:length))}
        for f in features where allowed.contains(f.subtype) {
            for part in f.parts where part.count>1 {
                for i in 1..<part.count {
                    let a=part[i-1],b=part[i];if a==b {continue};segments+=1;if segments>350_000 {throw RouteFailure.tooLarge}
                    let ai=getNode(a),bi=getNode(b),w=distance(a,b);connect(ai,bi,w)
                    let dx=b.x-a.x,dy=b.y-a.y,denom=dx*dx+dy*dy
                    for (which,p) in [start,end].enumerated() {
                        let t=max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/denom)),q=MapPoint(x:a.x+t*dx,y:a.y+t*dy)
                        let squared=pow(p.x-q.x,2)+pow(p.y-q.y,2)
                        if nearest[which] == nil || squared<nearest[which]!.squared {nearest[which]=Snap(squared:squared,fraction:t,point:q,from:ai,to:bi,length:w)}
                    }
                }
            }
        }
        guard let a=nearest[0],let b=nearest[1] else {throw RouteFailure.noNearby}
        let aOffset=distance(start,a.point),bOffset=distance(end,b.point)
        guard aOffset<=100 && bOffset<=100 else {throw RouteFailure.noNearby}
        let startID=nodes.count;nodes.append(a.point);graph.append([])
        let endID=nodes.count;nodes.append(b.point);graph.append([])
        connect(startID,a.from,a.fraction*a.length);connect(startID,a.to,(1-a.fraction)*a.length)
        connect(endID,b.from,b.fraction*b.length);connect(endID,b.to,(1-b.fraction)*b.length)
        if a.from==b.from && a.to==b.to || a.from==b.to && a.to==b.from {connect(startID,endID,distance(a.point,b.point))}
        var costs=[Double](repeating:.infinity,count:nodes.count),previous=[Int](repeating:-1,count:nodes.count),heap=Heap()
        costs[startID]=0;heap.push((0,startID))
        while let (cost,current)=heap.pop() {
            if cost != costs[current] {continue};if current==endID {break}
            for edge in graph[current] {
                let next=cost+edge.length
                if next<costs[edge.node] {costs[edge.node]=next;previous[edge.node]=current;heap.push((next,edge.node))}
            }
        }
        guard costs[endID].isFinite else {throw RouteFailure.disconnected}
        var path=[MapPoint](),current=endID
        while current != startID {path.append(nodes[current]);current=previous[current];if current<0 {throw RouteFailure.disconnected}}
        path.append(nodes[startID]);path.reverse();path.insert(start,at:0);path.append(end)
        return WalkingRoute(points:path,distance:costs[endID]+aOffset+bOffset)
    }
}
