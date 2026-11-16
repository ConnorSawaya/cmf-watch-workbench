import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CompanionCore
let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
let map=try OfflineMap(url:root.appendingPathComponent("build/demo/demo-map.cmfmap"))
func project(_ lon:Double,_ lat:Double)->MapPoint {.init(x:6_378_137*lon*Double.pi/180,y: -6_378_137*log(tan(Double.pi/4+lat*Double.pi/360)))}
func png(_ r:WatchRaster,_ name:String)throws {
 var pixels=[UInt8](),i=1;let b=Array(r.data)
 if b[0]==1 {pixels=(0..<450*257).map{i in b[1+Int((b[5+i/4]>>(6-2*(i%4)))&3)]}}else {
 while i<b.count {
  let v=b[i];i+=1
  if v>>4==15 {let n=Int(v&15)+1;for _ in 0..<n {let p=b[i];i+=1;pixels.append(p>>4);pixels.append(p&15)}}
  else {let n:Int;if v&15==15 {n=16+Int(b[i]);i+=1}else{n=1+Int(v&15)};pixels.append(contentsOf:repeatElement(v>>4,count:n))}
 }
 }
 guard pixels.count==450*257 else{throw TransferError.invalidMap}
 var rgba=[UInt8]();for p in pixels {let c=WatchRaster.palette[Int(p)];rgba.append(UInt8((c>>11)&31)*8);rgba.append(UInt8((c>>5)&63)*4);rgba.append(UInt8(c&31)*8);rgba.append(255)}
 let data=Data(rgba);let provider=CGDataProvider(data:data as CFData)!
 let image=CGImage(width:450,height:257,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:450*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
 let url=root.appendingPathComponent("build/artwork-check/\(name).png")
 let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,image,nil);guard CGImageDestinationFinalize(dest) else{throw TransferError.invalidMap}
}
var failed=false
for (name,center,scale) in [("overview",project(7.425,43.737),30.0),("monaco",project(7.425,43.737),8.0),("monaco12",project(7.425,43.737),12.0),("monaco16",project(7.425,43.737),16.0),("monaco6",project(7.425,43.737),6.0),("harbor",project(7.427,43.734),4.0),("coast",project(7.432,43.738),4.0),("park",project(7.421,43.736),2.0),("country",project(7.425,43.737),60.0)] {
 let start=Date(),radius=scale*235
 let f=map.visibleFeatures(bounds:[center.x-radius,center.y-radius,center.x+radius,center.y+radius],scale:scale<128 ? min(scale,4):scale)
 do {
  let r=try MapArtwork.make(center:center,scale:scale,states:map.states,features:f,route:nil)
  try png(r,name);print("\(name): \(f.count) source features, \(r.data.count) encoded bytes, \(Int(Date().timeIntervalSince(start)*1000)) ms")
  let fixture:[String:Any] = ["messages":r.messages(id:500).map{$0.map{String(format:"%02x",$0)}.joined()},"name":name]
  try JSONSerialization.data(withJSONObject:fixture).write(to:root.appendingPathComponent("build/artwork-check/\(name)-fixture.json"))
 }catch{print("\(name): failed \(error)");failed=true}
}

if failed {exit(1)}
