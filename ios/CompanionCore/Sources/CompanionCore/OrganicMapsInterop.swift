import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SharedMapPlace:Sendable,Equatable {
    public let name:String,latitude:Double,longitude:Double
    public init(name:String,latitude:Double,longitude:Double) throws {
        guard latitude.isFinite,longitude.isFinite,(-85...85).contains(latitude),(-180...180).contains(longitude) else{throw MapExchangeError.invalid}
        self.name=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(200));self.latitude=latitude;self.longitude=longitude
    }
}
public enum MapExchangeError:LocalizedError {
    case invalid,tooLarge,noPlaces
    public var errorDescription:String?{switch self{case .invalid:return "This place file or coordinate is invalid.";case .tooLarge:return "Import up to 1,000 places in a file smaller than 5 MB.";case .noPlaces:return "No saved point locations were found. Export bookmarks from Organic Maps as GPX or GeoJSON."}}
}
/// Uses the documented Organic Maps URL protocol, with no access to its tile cache.
public enum OrganicMapsInterop {
    public static func mapURL(places:[SharedMapPlace])->URL?{
        var c=URLComponents();c.scheme="om";c.host="map";var q=[URLQueryItem(name:"v",value:"1")]
        for p in places.prefix(32){q.append(.init(name:"ll",value:"\(p.latitude),\(p.longitude)"));q.append(.init(name:"n",value:p.name))}
        q += [.init(name:"backurl",value:"cmftrail://"),.init(name:"appname",value:"CMF Companion")];c.queryItems=q;return c.url
    }
    public static func callback(_ url:URL)throws->SharedMapPlace?{
        guard url.scheme=="cmftrail" else{throw MapExchangeError.invalid}
        guard url.host=="pin",let c=URLComponents(url:url,resolvingAgainstBaseURL:false) else{return nil}
        let q=c.queryItems ?? [];guard let ll=q.first(where:{$0.name=="ll"})?.value else{return nil};let v=ll.split(separator:",");guard v.count==2,let lat=Double(v[0]),let lon=Double(v[1]) else{throw MapExchangeError.invalid}
        return try SharedMapPlace(name:q.first(where:{$0.name=="n"})?.value ?? "Saved place",latitude:lat,longitude:lon)
    }
    public static func exportGPX(_ places:[SharedMapPlace])->Data{
        func escape(_ s:String)->String{s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;")}
        let points=places.map{"<wpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"><name>\(escape($0.name))</name></wpt>"}.joined(separator:"\n")
        return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"CMF Companion\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n\(points)\n</gpx>".utf8)
    }
    public static func importPlaces(_ data:Data)throws->[SharedMapPlace]{
        guard data.count<=5_000_000 else{throw MapExchangeError.tooLarge}
        var places=[SharedMapPlace]()
        if let root=try? JSONSerialization.jsonObject(with:data) as? [String:Any]{
            let features=(root["features"] as? [[String:Any]]) ?? (root["type"] as? String=="Feature" ? [root]:[])
            guard features.count<=100_000 else{throw MapExchangeError.tooLarge}
            for f in features {let g=f["geometry"] as? [String:Any] ?? f;guard g["type"] as? String=="Point",let xy=g["coordinates"] as? [Double],xy.count>=2 else{continue};let p=f["properties"] as? [String:Any];places.append(try SharedMapPlace(name:p?["name"] as? String ?? "Saved place",latitude:xy[1],longitude:xy[0]));guard places.count<=1000 else{throw MapExchangeError.tooLarge}}
        }else{
            let reader=Waypoints();let parser=XMLParser(data:data);parser.shouldResolveExternalEntities=false;parser.delegate=reader
            guard parser.parse(),!reader.failed else{throw MapExchangeError.invalid};places=reader.places
        }
        var seen=Set<String>();places=places.filter{seen.insert("\($0.name)|\($0.latitude)|\($0.longitude)").inserted}
        guard !places.isEmpty else{throw MapExchangeError.noPlaces};return places
    }
}
private final class Waypoints:NSObject,XMLParserDelegate{
    var places=[SharedMapPlace](),failed=false
    private var coordinate:(Double,Double)?,name="",readingName=false
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]){
        if name=="wpt" {guard let lat=attributes["lat"].flatMap(Double.init),let lon=attributes["lon"].flatMap(Double.init) else{failed=true;parser.abortParsing();return};coordinate=(lat,lon);self.name=""}
        if name=="name",coordinate != nil{readingName=true}
    }
    func parser(_ parser:XMLParser,foundCharacters string:String){if readingName{name+=string;if name.utf8.count>4096{failed=true;parser.abortParsing()}}}
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?){
        if name=="name"{readingName=false}
        if name=="wpt",let c=coordinate{do{places.append(try SharedMapPlace(name:self.name,latitude:c.0,longitude:c.1));guard places.count<=1000 else{throw MapExchangeError.tooLarge}}catch{failed=true;parser.abortParsing()};coordinate=nil}
    }
}
