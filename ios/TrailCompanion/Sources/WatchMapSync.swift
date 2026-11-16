import SwiftUI
import CoreLocation
import CompanionCore

struct SatelliteSymbol:View {
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:2).stroke(lineWidth:1.6).frame(width:8,height:11)
            HStack(spacing:10) {Rectangle().stroke(lineWidth:1.4).frame(width:8,height:12);Rectangle().stroke(lineWidth:1.4).frame(width:8,height:12)}
            Path {p in p.move(to:CGPoint(x:13,y:17));p.addLine(to:CGPoint(x:20,y:17));p.move(to:CGPoint(x:30,y:17));p.addLine(to:CGPoint(x:37,y:17))}.stroke(lineWidth:1.5)
        }.frame(width:48,height:34).rotationEffect(.degrees(-35)).frame(width:30,height:30).accessibilityHidden(true)
    }
}
struct LocationBadge:View {
    @EnvironmentObject var model:MapModel
    var body:some View {
        TimelineView(.periodic(from:.now,by:10)) {_ in
            HStack(spacing:8) {
                SatelliteSymbol().foregroundStyle(model.location.fresh ? Color.blue:.secondary)
                VStack(alignment:.leading,spacing:3) {
                    Text("Satellites —").font(.caption.weight(.semibold))
                    Text(model.location.ageLabel).font(.caption2).foregroundStyle(.secondary)
                    if let p=model.location.location {Text("Accuracy ±\(Int((p.horizontalAccuracy*3.28084).rounded())) ft").font(.caption2).foregroundStyle(.secondary)}
                }
            }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                .accessibilityElement(children:.combine).accessibilityHint("Satellite count is unavailable from iPhone location services")
        }.allowsHitTesting(false)
    }
}

struct WatchSnapshotBuilder {
    static func make(center c:MapPoint,scale:Double,label:String,features:[MapFeature],route:WalkingRoute?)throws->WatchSnapshot {
        let scale=UInt16(max(1,min(60000,scale.rounded())))
        var lines=[WatchMapLine]()
        if let route {lines.append(.init(points:route.points.map{.init(x:$0.x,y:$0.y)},kind:2))}
        for f in features {
            let kind:UInt8
            switch f.kind {
            case 0 where !f.closed: kind=["path","bridleway","footway","cycleway","steps"].contains(f.subtype) ? 1:0
            case 2,4:kind=3
            case 3,5:kind=4
            default:continue
            }
            for part in f.parts {lines.append(.init(points:part.map{.init(x:$0.x,y:$0.y)},kind:kind))}
        }
        // Q6 screen coordinates keep the vector fallback usable at national zoom.
        lines=lines.map {line in WatchMapLine(points:line.points.map{.init(x:($0.x-c.x)/Double(scale)*64,y:($0.y-c.y)/Double(scale)*64)},kind:line.kind)}
        let segments=WatchMapComposer.segments(lines:lines,center:.init(x:0,y:0),scale:64)
        return try WatchSnapshot(x:Int32(c.x.rounded()),y:Int32(c.y.rounded()),metersPerPixel:scale,label:label,segments:segments,screenCoordinates:true)
    }
}
extension MapModel {
    func makeWatchSnapshot(center:MapPoint,scale:Double,label:String) async throws->WatchSnapshot {
        // The watch displays the phone-rendered cartography. Send only camera
        // metadata here; a truncated line sample is not a map preview.
        return try WatchSnapshot(x:Int32(center.x.rounded()),y:Int32(center.y.rounded()),metersPerPixel:UInt16(max(1,min(60000,scale.rounded()))),label:label,segments:[],screenCoordinates:true)
    }
}

struct MapScaleBar:View {
    @EnvironmentObject var model:MapModel
    private var measure:(Double,String) {
        let meters=model.scale/cosh(model.center.y/6_378_137),feet=meters*3.28084
        let distances=[1.0,2,5,10,20,50,100,200,500,1000,2000,2640,5280,10560,26400,52800,105600,264000,528000,1056000,2640000,5280000,10560000]
        let value=distances.last(where:{$0<=feet*100}) ?? 1
        return (max(1,min(110,value/feet)),value>=2640 ? String(format:"%g mi",value/5280):String(format:"%g ft",value))
    }
    var body:some View {
        let (pixels,label)=measure
        VStack(alignment:.leading,spacing:4) {
            Text(label).font(.caption2.weight(.semibold)).monospacedDigit()
            Path {p in p.move(to:.init(x:0,y:0));p.addLine(to:.init(x:0,y:5));p.addLine(to:.init(x:pixels,y:5));p.addLine(to:.init(x:pixels,y:0))}.stroke(lineWidth:1.5).frame(width:pixels,height:6)
        }.padding(8).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).accessibilityLabel("Map scale \(label)").allowsHitTesting(false)
    }
}

extension MapModel {
    func makeWatchRaster(center:MapPoint,scale:Double) async throws->WatchRaster {
        guard let store else{throw TransferError.invalidMap}
        let route=route,pins=pins
        return try await withCheckedThrowingContinuation {completion in
            watchQueue.async {
                let radius=scale*235
                let features=store.visibleFeatures(bounds:[center.x-radius,center.y-radius,center.x+radius,center.y+radius],scale:scale)
                completion.resume(with:Result{try MapArtwork.make(center:center,scale:scale,states:store.states,features:features,route:route,pins:pins)})
            }
        }
    }
}
