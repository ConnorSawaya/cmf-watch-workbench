import Foundation
import CompanionCore

enum MapAssets {
    static var directory: URL {FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]}
    static var phoneURL:URL? {existing("offline.cmfmap") ?? Bundle.main.url(forResource:"demo-map",withExtension:"cmfmap")}
    static var watchURL:URL? {existing("offline.wp2map") ?? Bundle.main.url(forResource:"demo-map",withExtension:"wp2map")}
    static var phoneName:String {UserDefaults.standard.string(forKey:"imported-phone-map-name") ?? (phoneURL == nil ? "No offline map":"Monaco example")}
    static var watchName:String {UserDefaults.standard.string(forKey:"imported-watch-map-name") ?? (watchURL == nil ? "No offline area":"Monaco example")}
    private static func existing(_ name:String)->URL? {let p=directory.appendingPathComponent(name);return FileManager.default.fileExists(atPath:p.path) ? p:nil}
    static func importPhone(_ url:URL)throws {
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard (24...250_000_000).contains(size) else{throw MapError.malformed}
        _ = try OfflineMap(url:url)
        try Data(contentsOf:url).write(to:directory.appendingPathComponent("offline.cmfmap"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        UserDefaults.standard.set(url.deletingPathExtension().lastPathComponent,forKey:"imported-phone-map-name")
    }
    static func importWatch(_ url:URL)throws {
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard (64...9_200_000).contains(size) else{throw TransferError.invalidMap}
        let map=try WatchMapFile(Data(contentsOf:url))
        try map.data.write(to:directory.appendingPathComponent("offline.wp2map"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        UserDefaults.standard.set(url.deletingPathExtension().lastPathComponent,forKey:"imported-watch-map-name")
    }
    static var watchBytes:Int {(try? watchURL?.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0}
    static var phoneBytes:Int {(try? phoneURL?.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0}
    static func size(_ bytes:Int)->String {ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.decimal)}
}
