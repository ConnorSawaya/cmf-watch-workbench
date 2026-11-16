import Foundation
import CoreGraphics
import CoreText
import CompanionCore

/// Phone-rendered watch artwork uses the same map geometry and layers as Explore.
/// Geometry stays on the phone; only a bounded indexed viewport crosses BLE.
enum MapColors {
    static let components=WatchRaster.palette.map {v in (Int((v>>11)&31)*255/31,Int((v>>5)&63)*255/63,Int(v&31)*255/31)}
    static func color(_ i:Int)->CGColor {let c=components[i];return CGColor(red:Double(c.0)/255,green:Double(c.1)/255,blue:Double(c.2)/255,alpha:1)}
}
enum MapArtwork {
    static func make(center:MapPoint,scale:Double,states:[StateShape],features:[MapFeature],route:WalkingRoute?,pins:[SearchPlace]=[])throws->WatchRaster {
        let width=WatchRaster.width,height=WatchRaster.height
        let scale=max(1,min(60000,scale.rounded()))
        var rgba=[UInt8](repeating:0,count:width*height*4)
        let colors=MapColors.components
        func color(_ i:Int)->CGColor {MapColors.color(i)}
        try rgba.withUnsafeMutableBytes {bytes in
            guard let ctx=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{throw TransferError.invalidMap}
            ctx.translateBy(x:0,y:CGFloat(height));ctx.scaleBy(x:1,y:-1)
            ctx.setFillColor(color(states.isEmpty ? 1:0));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
            ctx.setAllowsAntialiasing(true);ctx.setShouldAntialias(true)
            ctx.saveGState();ctx.translateBy(x:225-center.x/scale,y:126-center.y/scale);ctx.scaleBy(x:1/scale,y:1/scale)
            for state in states {
                ctx.setFillColor(color(1));ctx.addPath(state.path);ctx.drawPath(using:.eoFill)
                ctx.setStrokeColor(color(10));ctx.setLineWidth(scale*0.8);ctx.addPath(state.path);ctx.strokePath()
            }
            ctx.setLineJoin(.round);ctx.setLineCap(.round)
            for layer in MapDrawingLayer.build(features) {
                ctx.addPath(layer.path)
                switch layer.kind {
                case 0:ctx.setStrokeColor(color(5));ctx.setLineWidth(scale*1.2);ctx.strokePath()
                case 1:ctx.setStrokeColor(color(7));ctx.setLineWidth(scale*1.6);ctx.strokePath()
                case 2:ctx.setStrokeColor(color(4));ctx.setLineWidth(scale);ctx.strokePath()
                default:ctx.setFillColor(color(layer.kind==4 ? 4:layer.kind==3 ? 2:12));ctx.drawPath(using:.eoFill)
                }
            }
            if let route,let first=route.points.first {
                let path=CGMutablePath();path.move(to:CGPoint(x:first.x,y:first.y));for p in route.points.dropFirst(){path.addLine(to:CGPoint(x:p.x,y:p.y))}
                ctx.addPath(path);ctx.setStrokeColor(color(5));ctx.setLineWidth(5*scale);ctx.strokePath()
                ctx.addPath(path);ctx.setStrokeColor(color(8));ctx.setLineWidth(3*scale);ctx.strokePath()
            }
            ctx.restoreGState()
            func position(_ p:MapPoint)->CGPoint {CGPoint(x:225+(p.x-center.x)/scale,y:126+(p.y-center.y)/scale)}
            var boxes=[CGRect](),names=Set<String>()
            func label(_ name:String,at p:CGPoint,ink:Int,size:CGFloat=13) {
                guard !name.isEmpty,name.count<70,p.x>12,p.x<Double(width-12),p.y>10,p.y<Double(height-10),names.insert(name).inserted else{return}
                let font=CTFontCreateUIFontForLanguage(.system,size,nil)!
                let attrs:[NSAttributedString.Key:Any]=[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color(ink)]
                let line=CTLineCreateWithAttributedString(NSAttributedString(string:name,attributes:attrs))
                let w=CTLineGetTypographicBounds(line,nil,nil,nil)
                let box=CGRect(x:p.x-w/2-3,y:p.y-11,width:w+6,height:21)
                guard box.minX>=1,box.maxX<Double(width-1),!boxes.contains(where:{$0.intersects(box)}) else{return};boxes.append(box)
                ctx.saveGState();ctx.translateBy(x:p.x-w/2,y:p.y+5);ctx.scaleBy(x:1,y:-1);ctx.textMatrix = .identity;ctx.textPosition = .zero;CTLineDraw(line,ctx);ctx.restoreGState()
            }
            if scale>=1500 {for state in states {label(state.abbreviation,at:position(state.center),ink:9)}}
            for feature in features.sorted(by:{$0.kind==7 && $1.kind != 7}) {
                guard boxes.count<35 else{break}
                let trail=feature.kind==0 && ["path","bridleway","footway","cycleway"].contains(feature.subtype)
                guard feature.kind==7 || (scale<50 && trail) || (scale<10 && feature.kind==0) else{continue}
                guard let part=feature.parts.first,!part.isEmpty else{continue}
                label(feature.name,at:position(part[part.count/2]),ink:trail ? 7:9,size:12)
            }
            for pin in pins {
                let p=position(pin.point);let r=CGRect(x:p.x-4,y:p.y-4,width:8,height:8)
                ctx.setFillColor(color(13));ctx.fillEllipse(in:r);ctx.setStrokeColor(color(5));ctx.setLineWidth(1.5);ctx.strokeEllipse(in:r)
            }
        }
        var pixels=[UInt8](repeating:0,count:width*height)
        for i in pixels.indices {
            let r=Int(rgba[4*i]),g=Int(rgba[4*i+1]),b=Int(rgba[4*i+2]);var best=Int.max,index=0
            for (j,c) in colors.prefix(15).enumerated() {let d=(r-c.0)*(r-c.0)+(g-c.1)*(g-c.1)+(b-c.2)*(b-c.2);if d<best {best=d;index=j;if d==0 {break}}}
            pixels[i]=UInt8(index)
        }
        return try WatchRaster(x:Int32(center.x.rounded()),y:Int32(center.y.rounded()),scale:UInt16(scale),pixels:pixels)
    }
}
