import Foundation
public struct WatchPairingCode:Sendable {
    public let suffix:String
    public init(_ text:String) throws {
        guard text.utf8.count<=1024,let url=URLComponents(string:text),url.scheme=="https",url.host?.lowercased()=="did6d9jhya79g.cloudfront.net",let fragment=url.fragment,fragment.hasPrefix("/qr?"),let qr=URLComponents(string:"https://local.invalid"+fragment),let items=qr.queryItems else{throw PairingError.invalidChallenge}
        var values=[String:String]()
        for item in items {guard values[item.name]==nil,let value=item.value else{throw PairingError.invalidChallenge};values[item.name]=value}
        guard values["p"]=="wapp1",let mac=values["M"],mac.count==12,mac.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) else{throw PairingError.invalidChallenge}
        suffix=String(mac.suffix(4)).uppercased()
    }
}
