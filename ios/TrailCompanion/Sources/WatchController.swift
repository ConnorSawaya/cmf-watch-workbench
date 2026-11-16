import Foundation
import Combine
import CoreLocation
import Security
import UIKit
import CryptoKit
import WireKit
import CompanionCore

@MainActor final class WatchController:ObservableObject {
    @Published var status="Ready to connect" {didSet {reportStatus()}}
    @Published var name="CMF Watch Pro 2"
    @Published var battery:Int?
    @Published var batteryCharging=false
    @Published var batteryUpdated:Date?
    @Published var connected=false
    @Published var busy=false
    @Published var progress:Double?
    @Published var message:String?
    @Published var apps:[Int:PackageHeader]=[:]
    @Published var sharingLocation=false
    @Published var stockPaired=false
    @Published var firmwareVersion:String?=UserDefaults.standard.string(forKey:"watch-firmware") {
        didSet {if let firmwareVersion {UserDefaults.standard.set(firmwareVersion,forKey:"watch-firmware")}}
    }
    @Published var pairingHint:String?
    @Published var health=WatchHealth()
    @Published var alarms:[WatchAlarm]?
    @Published var contacts:[WatchContact]?
    @Published var reminders:[UInt16:WatchReminder]=[:]
    @Published var wristWake:Bool?
    @Published var featureStatus="Changes are confirmed by the watch before being marked saved."
    @Published var loaderVerified=UserDefaults.standard.bool(forKey:"loader-verified")
    @Published var standardFeaturesEnabled=UserDefaults.standard.bool(forKey:"stock-features-enabled")
    @Published var autoSync=UserDefaults.standard.object(forKey:"watch-auto-sync") as? Bool ?? true {
        didSet {UserDefaults.standard.set(autoSync,forKey:"watch-auto-sync");if autoSync {scheduleAutoSync()}}
    }
    @Published var runningApp:String?
    var trailMapInstalled:Bool {apps.values.contains{$0.kind==0 && $0.name=="trail-map"}}
    @Published var autoMapSync=UserDefaults.standard.object(forKey:"watch-auto-map") as? Bool ?? true {didSet {UserDefaults.standard.set(autoMapSync,forKey:"watch-auto-map");startMapLink()}}
    @Published var autoPhoneGPS=UserDefaults.standard.object(forKey:"watch-auto-gps") as? Bool ?? true {didSet {UserDefaults.standard.set(autoPhoneGPS,forKey:"watch-auto-gps");startMapLink()}}
    @Published var mapSyncStatus="Open Trail Map on your watch to sync"
    private weak var mapModel:MapModel?
    private var cachedSnapshot:WatchSnapshot?
    private var cachedRaster:WatchRaster?
    private var watchViewport:WatchViewport?
    private var watchCachedMap:WatchCachedMap?
    @Published var savedMapViews=0
    @Published var watchCacheAvailable=false
    @Published var watchCacheError=0
    private var watchCacheHits=0,watchCacheWrites=0
    @Published var watchGPSActive=false
    @Published var watchGPSHasFix=false
    @Published var watchSatellites:Int?
    @Published var watchOfflineMapBytes=0
    @Published var watchMapTrailSegments=0
    @Published var watchMapFreeBytes=0
    @Published var downloadingWatchMap=false
    @Published var watchMapDownloadBytes=0
    private var nativeMapRequested=CommandLine.arguments.contains("-download-watch-map")
    private var nativeMapAttempt=Date.distantPast
    @Published var waitingForWatchUpdate=false
    private var queuedUpdateTask:Task<Void,Never>?
    private var lastPlacesCRC:UInt32?
    @Published var watchSavedPlaces=0
    private var lastMapSource:String?
    private var lastMapCRC:UInt32?
    private var lastMapSuccess:Date?
    private var lastMapAttempt:Date?
    private var autoSyncTask:Task<Void,Never>?
    private var foreground=true
    private var lastAutoAttempt:Date?
    private var lastClockUptime:TimeInterval?
    private var stock:StockConnection?
    private var pairingRequested=false
    private var installWatchAppsRequested=CommandLine.arguments.contains("-install-watch-apps")
    private var setupStandardRequested=CommandLine.arguments.contains("-setup-standard-controls")
    private var syncHealthRequested=CommandLine.arguments.contains("-sync-health")
    private var flashPreparedRequested=CommandLine.arguments.contains("-flash-prepared-firmware")
    @Published var faces=FaceLibrary.load()
    @Published var faceStatus=""
    func saveFace(_ file:FaceFile) {do{_ = try FaceLibrary.add(file);faces=FaceLibrary.load();faceStatus="Face saved on this phone"}catch{message=error.localizedDescription}}
    func faceIsInstalled(_ face:SavedFace)->Bool {face.dialID != nil && face.installedDevice==ble?.identifier}
    func deleteLocalFace(_ face:SavedFace) {do {let kept=faces.filter{$0.id != face.id};try FaceLibrary.save(kept);try? FileManager.default.removeItem(at:face.file);try? FileManager.default.removeItem(at:face.thumbnail);faces=kept}catch{message=error.localizedDescription}}
    func installFace(_ face:SavedFace) {
        guard !faceIsInstalled(face) else{return}
        guard runningApp==nil else{message="Close the custom app on the watch before installing a face.";return}
        guard let device=ble?.identifier else{message="Connect the watch before installing a face.";return}
        stockOperation("Installing watch face…") {s in
            let file=try FaceFile(Data(contentsOf:face.file)),id=(face.pendingDevice==device ? face.pendingDialID:nil) ?? UInt32.random(in:10000..<0x7fffffff)
            var pending=self.faces;if let i=pending.firstIndex(where:{$0.id==face.id}){pending[i].pendingDialID=id;pending[i].pendingDevice=device};try FaceLibrary.save(pending);self.faces=pending
            UIApplication.shared.isIdleTimerDisabled=true;defer{UIApplication.shared.isIdleTimerDisabled=false}
            try await s.uploadFace(file,id:id,progress:{n in await MainActor.run {self.progress=Double(n)/Double(file.data.count);self.faceStatus=n==file.data.count ? "Activating face…":"Sending face: \(n.formatted()) / \(file.data.count.formatted()) bytes"}})
            var list=self.faces;if let i=list.firstIndex(where:{$0.id==face.id}){list[i].dialID=id;list[i].installedDevice=device;list[i].pendingDialID=nil;list[i].pendingDevice=nil};try FaceLibrary.save(list);self.faces=list;self.faceStatus="Watch confirmed the face is active"
        }
    }
    func removeFace(_ face:SavedFace) {
        guard runningApp==nil,faceIsInstalled(face),let id=face.dialID else{return}
        stockOperation("Removing watch face…") {s in
            let file=try FaceFile(Data(contentsOf:face.file));try await s.uploadFace(file,id:id,delete:true)
            var list=self.faces;if let i=list.firstIndex(where:{$0.id==face.id}){list[i].dialID=nil;list[i].installedDevice=nil};try FaceLibrary.save(list);self.faces=list;self.faceStatus="Watch confirmed the face was removed"
        }
    }
    private var installPreparedRequested=CommandLine.arguments.contains("-install-prepared-code")
    @Published var firmwareStatus="Loader firmware has not been checked"
    private var ble:WatchBLE?
    private var session:KSession?
    private var operation:Task<Void,Never>?
    private var gpsTask:Task<Void,Never>?
    private var sessionGeneration=0
    private var lastDiagnosticProgress=Date.distantPast
    init() {
        if CommandLine.arguments.contains("-export-test-face"),let file=try? FaceArtwork.make(name:"Workbench",accent:.white,rounded:true,photo:nil){try? FaceLibrary.add(file);faces=FaceLibrary.load()}
        if let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
           let data=try? Data(contentsOf:dir.appendingPathComponent("watch-health.json")),
           let saved=try? JSONDecoder().decode(WatchHealth.self,from:data) {health=saved}
        if let i=CommandLine.arguments.firstIndex(of:"-watch-suffix"),i+1<CommandLine.arguments.count {
            let suffix=CommandLine.arguments[i+1].uppercased()
            if suffix.count==4,suffix.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)}) {pairingHint=suffix}
        }
        if CommandLine.arguments.contains("-pair-reset") {DispatchQueue.main.async {self.pairResetWatch()}}
        else if CommandLine.arguments.contains("-connect-watch") || (standardFeaturesEnabled && UserDefaults.standard.object(forKey:"watch-auto-connect") as? Bool != false) {DispatchQueue.main.async {self.connect()}}
        autoSyncTask=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(60))
                guard !Task.isCancelled else{return}
                self?.scheduleAutoSync()
            }
        }
    }
    private func reportStatus() {
        guard CommandLine.arguments.contains("-diagnostics"),let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{return}
        if status.hasPrefix("Firmware sent:") {
            guard Date().timeIntervalSince(lastDiagnosticProgress)>=1 else{return}
            lastDiagnosticProgress=Date()
        }
        let record:[String:Any]=["status":status,"stockPaired":stockPaired,"customConnected":connected,"firmware":firmwareVersion ?? "unknown","battery":battery ?? -1,"standardControls":standardFeaturesEnabled,"featureStatus":featureStatus,"apps":apps.values.map{$0.name}.sorted(),"autoSync":autoSync,"runningApp":runningApp ?? "none","mapSync":mapSyncStatus,"autoMap":autoMapSync,"savedMapViews":savedMapViews,"watchCacheAvailable":watchCacheAvailable,"watchCacheHits":watchCacheHits,"watchCacheWrites":watchCacheWrites,"watchCacheError":watchCacheError,"appVersions":Dictionary(uniqueKeysWithValues:apps.values.map{($0.name,$0.version)})]
        var diagnostics=record;diagnostics["watchSavedPlaces"]=watchSavedPlaces;diagnostics["watchGPSActive"]=watchGPSActive;diagnostics["watchGPSHasFix"]=watchGPSHasFix;diagnostics["watchSatellites"]=watchSatellites ?? -1;diagnostics["watchOfflineMapBytes"]=watchOfflineMapBytes;diagnostics["watchMapTrailSegments"]=watchMapTrailSegments;diagnostics["watchMapFreeBytes"]=watchMapFreeBytes;diagnostics["watchMapDownloadBytes"]=watchMapDownloadBytes;diagnostics["downloadingWatchMap"]=downloadingWatchMap
        if let data=try? JSONSerialization.data(withJSONObject:diagnostics,options:.sortedKeys) {try? data.write(to:dir.appendingPathComponent("connection-status.json"),options:.atomic)}
    }
    func acceptQR(_ raw:String) {
        do {let code=try WatchPairingCode(raw);pairingHint=code.suffix;status="Watch QR recognized. Ready to pair."}
        catch {message="This QR code is not a supported CMF Watch setup code."}
    }
    func pairResetWatch() {pairingRequested=true;connect()}
    func connect() {
        UserDefaults.standard.set(true,forKey:"watch-auto-connect")
        if ble==nil {
            let b=WatchBLE();b.onState={ [weak self] state in self?.stateChanged(state) };b.onName={ [weak self] in self?.name=$0 };ble=b
        }
        ble?.desiredSuffix=pairingHint
        ble?.connect()
    }
    func disconnect() {
        UserDefaults.standard.set(false,forKey:"watch-auto-connect")
        if let session {Task {await session.close()}}
        operation?.cancel();gpsTask?.cancel();gpsTask=nil;sharingLocation=false;sessionGeneration+=1;lastPlacesCRC=nil;session=nil;stockPaired=false;connected=false;runningApp=nil;busy=false;progress=nil;ble?.disconnect()
    }
    private func stateChanged(_ state:WatchBLE.State) {
        switch state {
        case .off:status="Turn on Bluetooth and allow access in Settings";connected=false
        case .searching:status="Searching for Watch Pro 2…"
        case .connecting:status="Connecting…"
        case .disconnected:operation?.cancel();lastPlacesCRC=nil;busy=false;progress=nil;status="Disconnected";session=nil;stockPaired=false;connected=false;runningApp=nil;sharingLocation=false;gpsTask?.cancel();gpsTask=nil;sessionGeneration+=1
        case .failed(let reason):status=reason;connected=false
        case .ready:
            operation?.cancel()
            sessionGeneration+=1;let generation=sessionGeneration
            operation=Task {
                guard let ble else{return};busy=true;defer {if generation==sessionGeneration {busy=false}}
                do {
                    if pairingRequested {
                        status="Pairing reset watch…";let fresh=StockConnection(link:ble);await fresh.attach()
                        let auth=try await fresh.pair()
                        if let identifier=ble.identifier {WatchKeys.save(auth,device:identifier)}
                        stock=fresh;stockPaired=true;firmwareVersion=try? await fresh.readVersion();pairingRequested=false
                        status="Paired to stock watch";firmwareStatus="Ready for the initial loader firmware update"
                        schedulePreparedFirmwareIfRequested()
                        message="Bluetooth pairing completed. The loader firmware is a separate update; pairing alone does not add the map app."
                        return
                    }
                    status="Checking app loader…"
                    let (s,_)=try await KSession.open(link:ble)
                    guard generation==sessionGeneration else{return}
                    session=s;connected=true;loaderVerified=true;UserDefaults.standard.set(true,forKey:"loader-verified");status="Watch connected";firmwareStatus="Custom app channel is responding"
                    apps=try await WireKit.installed(s)
                    updateRunning(try await s.ping())
                    if setupStandardRequested {
                        setupStandardRequested=false
                        DispatchQueue.main.async {self.setupStandardFeatures()}
                    }else if installWatchAppsRequested {
                        installWatchAppsRequested=false
                        DispatchQueue.main.async {self.installWatchApps()}
                    }else if installPreparedRequested {
                        installPreparedRequested=false
                        DispatchQueue.main.async {self.installPreparedCode()}
                    }else if syncHealthRequested {
                        syncHealthRequested=false
                        DispatchQueue.main.async {self.syncHealth()}
                    }else if standardFeaturesEnabled {
                        DispatchQueue.main.async {self.scheduleAutoSync(refreshIfRecent:true,onConnection:true);self.startMapLink()}
                    }
                }catch {
                    guard generation==sessionGeneration else{return}
                    if let id=ble.identifier,let auth=WatchKeys.load(device:id) {
                        let resumed=StockConnection(link:ble);await resumed.attach()
                        do {try await resumed.resume(auth:auth);stock=resumed;stockPaired=true;firmwareVersion=try? await resumed.readVersion();status="Paired to stock watch";firmwareStatus="Ready for the initial loader firmware update";schedulePreparedFirmwareIfRequested();return}
                        catch {await resumed.close()}
                    }
                    status="Watch connected; custom loader did not respond"
                    firmwareStatus="The initial loader firmware must be installed first. This build does not flash firmware automatically."
                    message="The watch did not answer the custom app protocol. Stock firmware needs the initial loader patch; a Bluetooth connection alone cannot install code."
                }
            }
        }
    }
    private func schedulePreparedFirmwareIfRequested() {
        guard flashPreparedRequested else{return};flashPreparedRequested=false
        DispatchQueue.main.async {
            do {
                guard let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
                      let url=Bundle.main.url(forResource:"firmware-manifest",withExtension:"json"),
                      let m=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any],
                      let hash=m["sha256"] as? String,let bytes=m["bytes"] as? Int else{throw PairingError.invalidFirmware}
                let data=try Data(contentsOf:dir.appendingPathComponent("fw-trail-loader.bin"),options:.mappedIfSafe)
                self.uploadFirmware(try FirmwareCandidate(data:data,expectedSHA256:hash,expectedBytes:bytes))
            }catch {self.message=error.localizedDescription}
        }
    }
    func uploadFirmware(_ candidate:FirmwareCandidate) {
        guard let stock,stockPaired,!busy else{return}
        guard let battery,battery>=50,let batteryUpdated,Date().timeIntervalSince(batteryUpdated)<120 else{message="Refresh the watch battery and charge it to at least 50% before updating firmware.";return}
        run {
            UIApplication.shared.isIdleTimerDisabled=true
            defer {UIApplication.shared.isIdleTimerDisabled=false}
            self.status="Sending firmware requested by watch…"
            try await stock.upload(candidate) {bytes in Task {@MainActor in self.status="Firmware sent: \(ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file))"}}
            self.status="Watch accepted update; waiting for reboot"
            self.message="The watch accepted the firmware image and received the final commit command. Wait for it to reboot, then reconnect and install the loader and Trail Map packages."
        }
    }
    func refresh() {
        guard let s=session,!busy else{return}
        run {self.apps=try await WireKit.installed(s);self.updateRunning(try await s.ping());self.status="Watch apps refreshed"}
    }
    private func testedPackage(_ package:ValidatedPackage)throws {
        guard let url=Bundle.main.url(forResource:"tested-packages",withExtension:"json"),
              let record=try JSONDecoder().decode([TestedPackage].self,from:Data(contentsOf:url)).first(where:{$0.name==package.header.name && $0.kind==package.header.kind}) else{throw CompanionPolicyError.untestedPackage}
        try record.verify(package)
    }
    func validateImported(_ data:Data)throws->ValidatedPackage {
        let package=try ValidatedPackage(data);try testedPackage(package);return package
    }
    private func preflightInstall() async throws->KSession {
        guard !sharingLocation else{throw CompanionPolicyError.closeWatchApp}
        guard let initial=session else{throw WireError.closed}
        let state=try await initial.ping();updateRunning(state)
        guard state.slot==255 else{throw CompanionPolicyError.closeWatchApp}
        try await performStock("Checking watch battery…") {s in self.acceptBattery(try await s.readBattery());self.firmwareVersion=try await s.readVersion()}
        guard let current=session else{throw WireError.closed}
        let live=try await current.ping();updateRunning(live)
        try CompanionPolicy.validateInstall(firmware:firmwareVersion,battery:battery,batteryAge:batteryUpdated.map{Date().timeIntervalSince($0)},runningSlot:live.slot)
        return current
    }
    private func confirmedInstall(_ package:ValidatedPackage,over s:KSession,progress:@escaping @Sendable(Double)->Void) async throws {
        try testedPackage(package)
        let slot=try await WireKit.install(s,package:package.data,progress:progress)
        apps=try await WireKit.installed(s)
        guard apps[slot]==package.header else{throw TransferError.noAcknowledgement}
    }
    func install(_ package:ValidatedPackage) {
        guard session != nil,!busy else{return}
        do {try testedPackage(package)}catch{message=error.localizedDescription;return}
        run {
            let s=try await self.preflightInstall()
            UIApplication.shared.isIdleTimerDisabled=true
            defer {UIApplication.shared.isIdleTimerDisabled=false}
            self.status="Installing \(package.header.name)…";self.progress=0
            try await self.confirmedInstall(package,over:s) {p in Task {@MainActor in self.progress=p}}
            self.status="\(package.header.name) installed"
            self.message="Installed and confirmed by your watch. Open Custom Apps → \(package.header.name) on the watch."
        }
    }
    func installPreparedCode() {
        do {
            guard let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else{throw TransferError.invalidPackage}
            let url=dir.appendingPathComponent("trail-map.wp2app")
            let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
            guard let size=attrs[.size] as? NSNumber,size.intValue<=262208 else{throw TransferError.invalidPackage}
            let package=try ValidatedPackage(Data(contentsOf:url,options:.mappedIfSafe))
            guard package.header.kind==0,package.header.name=="trail-map" else{throw TransferError.invalidPackage}
            install(package)
        }catch {message=error.localizedDescription}
    }
    func installWatchApps() {
        guard session != nil,!busy else{return}
        do {
            guard let loaderURL=Bundle.main.url(forResource:"loader",withExtension:"wp2app"),let mapURL=Bundle.main.url(forResource:"trail-map",withExtension:"wp2app") else{throw TransferError.invalidPackage}
            let loader=try validateImported(Data(contentsOf:loaderURL)),map=try validateImported(Data(contentsOf:mapURL))
            run {
                let s:KSession
                do {s=try await self.preflightInstall()}
                catch CompanionPolicyError.closeWatchApp {self.queueWatchUpdate();return}
                UIApplication.shared.isIdleTimerDisabled=true
                defer {UIApplication.shared.isIdleTimerDisabled=false}
                self.apps=try await WireKit.installed(s)
                if self.apps[255] != loader.header {
                    self.status="Updating app launcher…";self.progress=0
                    do {try await self.confirmedInstall(loader,over:s) {p in Task {@MainActor in self.progress=p*0.7}}}
                    catch InstallError.busy {self.queueWatchUpdate();return}
                }
                guard self.apps[255]==loader.header else{throw CompanionPolicyError.untestedPackage}
                self.status="Installing Trail Map…"
                do {try await self.confirmedInstall(map,over:s) {p in Task {@MainActor in self.progress=0.7+p*0.3}}}
                catch InstallError.busy {self.queueWatchUpdate();return}
                self.status="Trail Map installed"
                self.message="Trail Map is installed and confirmed. On your watch, open Custom Apps → trail-map. Then choose an area in Explore and send it from Watch apps."
            }
        }catch {message=error.localizedDescription}
    }
    private func queueWatchUpdate() {
        guard queuedUpdateTask==nil else{return}
        waitingForWatchUpdate=true;status="Update ready. Close Trail Map and Custom Apps on the watch."
        queuedUpdateTask=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(15))}catch{return}
                guard let self else{return}
                if self.connected,!self.busy,self.runningApp==nil {
                    self.queuedUpdateTask=nil;self.waitingForWatchUpdate=false;self.installWatchApps();return
                }
            }
        }
    }
    func cancelQueuedWatchUpdate() {queuedUpdateTask?.cancel();queuedUpdateTask=nil;waitingForWatchUpdate=false;status="Watch app update cancelled"}
    var availableAppPackages:[TestedPackage] {
        guard let url=Bundle.main.url(forResource:"tested-packages",withExtension:"json"),let data=try? Data(contentsOf:url),let records=try? JSONDecoder().decode([TestedPackage].self,from:data) else{return []}
        return records.filter{$0.kind==0 && $0.name != "trail-map"}
    }
    func installBundled(_ name:String) {
        do {guard let url=Bundle.main.url(forResource:name,withExtension:"wp2app") else {throw TransferError.invalidPackage};install(try ValidatedPackage(Data(contentsOf:url)))}catch {message=error.localizedDescription}
    }
    func syncHealth(automatic:Bool=false) {
        lastAutoAttempt=Date()
        stockOperation("Syncing watch…",quiet:automatic) {s in
            UIApplication.shared.isIdleTimerDisabled=true
            defer {UIApplication.shared.isIdleTimerDisabled=false}
            self.acceptBattery(try await s.readBattery())
            let new=try await s.syncHealth();self.health.merge(new)
            if let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
               let data=try? JSONEncoder().encode(self.health) {try data.write(to:dir.appendingPathComponent("watch-health.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
            if let data=try? await s.readFeature(0x63) {self.alarms=try? WatchAlarm.decode(data)}
            self.featureStatus="Health, battery and clock are up to date."
        }
    }
    func refreshBattery() {
        stockOperation("Reading watch battery…") {s in
            self.acceptBattery(try await s.readBattery())
            self.featureStatus="Battery read directly from watch"
        }
    }
    private func acceptBattery(_ value:WatchBattery) {
        battery=value.percent;batteryCharging=value.charging;batteryUpdated=Date()
    }
    func loadAlarms() {stockOperation("Reading alarms…") {s in self.alarms=try WatchAlarm.decode(await s.readFeature(0x63));self.featureStatus="Alarms read from watch"}}
    func saveAlarms(_ values:[WatchAlarm]) {
        guard alarms != nil else{message="Read the watch's alarms before changing them.";return}
        stockOperation("Saving alarms…") {s in try await s.writeFeature(0x63,WatchAlarm.encode(values));let saved=try WatchAlarm.decode(await s.readFeature(0x63));guard saved.count==values.count else{throw StockFeatureError.unavailable};self.alarms=saved;self.featureStatus="Alarms saved and read back from watch"}
    }
    func loadContacts() {stockOperation("Reading contacts…") {s in self.contacts=try WatchContact.decode(await s.readFeature(0xd5));self.featureStatus="Contacts read from watch"}}
    func saveContacts(_ values:[WatchContact]) {
        guard contacts != nil else{message="Read the watch's contacts before replacing them.";return}
        stockOperation("Saving contacts…") {s in try await s.writeFeature(0xd5,WatchContact.encode(values));let saved=try WatchContact.decode(await s.readFeature(0xd5));guard saved.count==values.count else{throw StockFeatureError.unavailable};self.contacts=saved;self.featureStatus="Contacts saved and read back from watch"}
    }
    func loadReminder(_ ability:UInt16) {stockOperation("Reading reminder…") {s in self.reminders[ability]=try WatchReminder(data:await s.readFeature(ability));self.featureStatus="Reminder read from watch"}}
    func saveReminder(_ ability:UInt16,_ reminder:WatchReminder) {stockOperation("Saving reminder…") {s in try await s.writeFeature(ability,reminder.encoded());let saved=try WatchReminder(data:await s.readFeature(ability));guard saved==reminder else{throw StockFeatureError.unavailable};self.reminders[ability]=saved;self.featureStatus="Reminder saved and read back from watch"}}
    func applySetting(_ setting:WatchSetting) {stockOperation("Applying watch setting…") {s in try await s.apply(setting);self.featureStatus="Setting acknowledged by watch"}}
    func setupStandardFeatures() {
        stockOperation("Setting watch clock…",initialize:true) {s in
            let wrist=try await s.readFeature(0x62)
            guard wrist.count==1 else{throw StockFeatureError.invalidData}
            self.firmwareVersion=try? await s.readVersion()
            self.acceptBattery(try await s.readBattery())
            self.wristWake=wrist[0] != 0;self.standardFeaturesEnabled=true;UserDefaults.standard.set(true,forKey:"stock-features-enabled")
            if let data=try? await s.readFeature(0x63) {self.alarms=try? WatchAlarm.decode(data)}
            for a:UInt16 in [0x60,0x61] {if let data=try? await s.readFeature(a) {self.reminders[a]=try? WatchReminder(data:data)}}
            self.featureStatus="Clock sync completed; standard watch connection verified."
        }
    }
    private func stockOperation(_ title:String,initialize:Bool=false,quiet:Bool=false,_ work:@escaping @MainActor (StockConnection) async throws->Void) {
        guard (connected || stockPaired),ble != nil else{if !quiet {message="Connect your watch first."};return}
        guard !busy else{return}
        run(quiet:quiet) {try await self.performStock(title,initialize:initialize,work)}
    }
    private func performStock(_ title:String,initialize:Bool=false,_ work:@escaping @MainActor (StockConnection) async throws->Void) async throws {
        guard let ble else{throw WireError.closed}
        let generation=sessionGeneration
        gpsTask?.cancel();gpsTask=nil;sharingLocation=false
        if let session {await session.close()};session=nil
        let s=StockConnection(link:ble);await s.attach()
        var failure:Error?
        do {
            guard let id=ble.identifier,let auth=WatchKeys.load(device:id) else{throw PairingError.invalidChallenge}
            status=title
            try await s.resume(auth:auth)
            guard standardFeaturesEnabled || initialize else{throw StockFeatureError.clockSetupRequired}
            let now=Date(),offset=TimeZone.current.secondsFromGMT(for:Date())
            let previous=UserDefaults.standard.object(forKey:"watch-clock-epoch") as? Double
            let previousOffset=UserDefaults.standard.object(forKey:"watch-clock-offset") as? Int
            try CompanionPolicy.validateClock(epoch:now.timeIntervalSince1970,offset:offset,lastEpoch:previous,lastOffset:previousOffset,elapsed:lastClockUptime.map{ProcessInfo.processInfo.systemUptime-$0} ?? 0)
            try await s.initializeClock(epoch:UInt32(now.timeIntervalSince1970),offsetMilliseconds:Int32(offset*1000))
            UserDefaults.standard.set(now.timeIntervalSince1970,forKey:"watch-clock-epoch");UserDefaults.standard.set(offset,forKey:"watch-clock-offset");lastClockUptime=ProcessInfo.processInfo.systemUptime
            try await work(s)
        }catch {failure=error}
        await s.close()
        guard generation==sessionGeneration,!Task.isCancelled else{throw CancellationError()}
        if let (new,_)=try? await KSession.open(link:ble) {session=new;connected=true;updateRunning(try await new.ping());startMapLink()}
        else {connected=false}
        if let failure {featureStatus="Sync or change could not be confirmed. \(failure.localizedDescription)";throw failure}
        status="Watch connected"
    }
    private func updateRunning(_ state:(slot:UInt8,flags:UInt8)) {
        runningApp=state.slot==255 ? nil : apps[Int(state.slot)]?.name ?? "Watch app"
        reportStatus()
    }
    private func scheduleAutoSync(refreshIfRecent:Bool=false,onConnection:Bool=false) {
        guard connected,standardFeaturesEnabled,!busy,!sharingLocation,foreground,autoSync else{return}
        if CompanionPolicy.syncDue(now:Date(),lastSync:health.syncedAt,lastAttempt:lastAutoAttempt,foreground:foreground,enabled:autoSync,busy:busy,sharingGPS:sharingLocation,minimumInterval:onConnection ? 60:900) {
            guard let s=session else{return}
            lastAutoAttempt=Date()
            // Check without taking over the live app's channel or interrupting its GPS.
            run(quiet:true) {
                let state=try await s.ping();self.updateRunning(state)
                guard state.slot==255 else{self.status="Watch connected";return}
                DispatchQueue.main.async {self.syncHealth(automatic:true)}
            }
        }else if refreshIfRecent,runningApp==nil,batteryUpdated.map({Date().timeIntervalSince($0)>300}) ?? true {refreshBattery()}
    }
    func syncNow() async {
        syncHealth()
        let current=operation
        await current?.value
    }
    func sendMap(_ model:MapModel) {
        guard let s=session,!busy else{return}
        guard apps.values.contains(where:{$0.name=="trail-map" && $0.version>=6}) else{message="Update Trail Map in Watch apps for full US coverage and map artwork.";return}
        run {
            self.watchViewport=nil;self.watchCachedMap=nil
            let center:MapPoint,scale:Double,label:String
            if model.scale<=60000 {center=model.center;scale=model.scale;label=model.selected?.name ?? "Offline area"}
            else if let selected=model.selected {center=selected.point;scale=8;label=selected.name}
            else if let fix=model.location.location {center=MapModel.project(fix.coordinate);scale=8;label="Nearby offline area"}
            else if let saved=self.cachedSnapshot {center=MapPoint(x:Double(saved.centerX),y:Double(saved.centerY));scale=Double(saved.scale);label=saved.label}
            else {center=model.center;scale=8;label="Offline area"}
            let snapshot=try await model.makeWatchSnapshot(center:center,scale:scale,label:label)
            self.status="Preparing map artwork…";self.progress=0
            try await sendSnapshot(snapshot,over:s,id:UInt16.random(in:1...65535),progress:{p in Task {@MainActor in self.progress=p}},received:{[weak self] d in await self?.receiveMapMessage(d)})
            self.progress=nil;self.status="Sending map artwork…"
            let artwork=try await model.makeWatchRaster(center:center,scale:scale)
            try await sendRaster(artwork,over:s,id:UInt16.random(in:1...65535),received:{[weak self] d in await self?.receiveMapMessage(d)})
            self.cachedRaster=artwork
            self.cachedSnapshot=snapshot;self.lastMapCRC=WireKit.crc32(snapshot.data)^WireKit.crc32(artwork.data);self.lastMapSuccess=Date();self.mapSyncStatus="Map synced to watch"
            if let file=self.mapFile {try? snapshot.data.write(to:file,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
            self.status="Map ready on watch";self.message="The watch confirmed the map artwork. US state outlines remain available without the phone. Keep this app open for full map detail and live location."
        }
    }
    private func receiveMapMessage(_ data:Data) {
        if let cached=WatchCachedMap(message:data) {watchViewport=cached.viewport;watchCachedMap=cached}
        else if let view=WatchViewport(message:data) {watchViewport=view;watchCachedMap=nil}
        else if let info=WatchMapCacheStatus(message:data) {savedMapViews=info.count;watchCacheAvailable=info.available;watchCacheHits=info.hits;watchCacheWrites=info.writes;watchCacheError=info.error;reportStatus()}
        else if let info=WatchOfflineMapInfo(message:data) {acceptOfflineMapInfo(info)}
        else if data.count==10,Array(data.prefix(4))==[84,77,1,0x44]{watchSavedPlaces=Int(data[4])}
        else if data.count==7,Array(data.prefix(4))==[84,77,1,0x17] {watchGPSActive=data[4]==1;watchGPSHasFix=data[5]==1;watchSatellites=data[6]<=100 ? Int(data[6]):nil;reportStatus()}
        else if data==Data([84,77,1,0x10]) {lastMapCRC=nil;lastMapSource=nil;watchCachedMap=nil}
    }
    private func acceptOfflineMapInfo(_ info:WatchOfflineMapInfo) {watchOfflineMapBytes=info.bytes;watchMapTrailSegments=info.trailSegments;watchMapFreeBytes=info.freeBytes;reportStatus()}
    func downloadWatchMap() {
        guard let s=session,!busy,runningApp=="trail-map" else {nativeMapRequested=true;mapSyncStatus="Open Trail Map on the watch to download its hiking map";return}
        guard apps.values.contains(where:{$0.name=="loader" && $0.version>=4}),apps.values.contains(where:{$0.name=="trail-map" && $0.version>=9}) else {message="Update Trail Map before downloading the offline hiking map.";return}
        nativeMapAttempt=Date();nativeMapRequested=true
        run {
            guard let url=MapAssets.watchURL else{throw TransferError.invalidMap}
            let map=try WatchMapFile(Data(contentsOf:url,options:.mappedIfSafe))
            if map.codec==2 {
                guard self.apps.values.contains(where:{$0.name=="loader" && $0.version>=5}),self.apps.values.contains(where:{$0.name=="trail-map" && $0.version>=11}) else{throw TransferError.mapUpdateRequired}
            }
            let data=map.data
            self.downloadingWatchMap=true;UIApplication.shared.isIdleTimerDisabled=true
            defer {self.downloadingWatchMap=false;UIApplication.shared.isIdleTimerDisabled=false}
            self.status="Downloading offline hiking map…";self.mapSyncStatus="Downloading hiking map to watch…"
            let info=try await sendOfflineMap(data,version:1,over:s,progress:{[weak self] bytes in
                await MainActor.run {guard let self else{return};self.watchMapDownloadBytes=bytes;self.progress=Double(bytes)/Double(data.count);self.mapSyncStatus="Downloading to watch: \(Int(self.progress!*100))%";self.reportStatus()}
            },received:{[weak self] d in await self?.receiveMapMessage(d)})
            self.acceptOfflineMapInfo(info);self.nativeMapRequested=false;self.mapSyncStatus="Offline hiking map saved on watch";self.status="Offline map ready on watch"
        }
    }

    private func run(quiet:Bool=false,_ body:@escaping @MainActor () async throws->Void) {
        guard !busy else{return};busy=true
        let generation=sessionGeneration
        operation=Task {
            defer {if generation==sessionGeneration {busy=false;progress=nil;startMapLink()}}
            do {try await body()}catch {
                guard generation==sessionGeneration,!Task.isCancelled else{return}
                status="Operation stopped: \(Self.describe(error))";if !quiet {message=Self.describe(error)}
            }
        }
    }
    func setForeground(_ active:Bool) {
        foreground=active
        if !active {mapModel?.location.persistLastLocation();stopLocation(userInitiated:false)}
        else if connected {startMapLink();scheduleAutoSync(refreshIfRecent:true)}
        else if standardFeaturesEnabled,autoSync,UserDefaults.standard.object(forKey:"watch-auto-connect") as? Bool != false {connect()}
    }
    func configureMapSync(_ model:MapModel) {
        mapModel=model
        if let file=mapFile,let data=try? Data(contentsOf:file) {cachedSnapshot=try? WatchSnapshot(data:data)}
        startMapLink()
    }
    private var mapFile:URL? {FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.appendingPathComponent("watch-area.bin")}
    func stopLocation(userInitiated:Bool=true) {
        let wasSharing=sharingLocation
        gpsTask?.cancel();gpsTask=nil;sharingLocation=false
        if userInitiated {autoPhoneGPS=false}
        if wasSharing,!busy,let s=session {run {try await s.send(Data([84,77,1,5]))}}
    }
    func startLocation(_ provider:LocationProvider) {provider.start();autoPhoneGPS=true;startMapLink()}
    private func startMapLink() {
        guard gpsTask==nil,foreground,connected,mapModel != nil else{return}
        let generation=sessionGeneration
        gpsTask=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,generation==self.sessionGeneration else{return}
                if self.foreground,self.connected,!self.busy,let s=self.session,let model=self.mapModel {
                    self.busy=true
                    do {
                        let previous=self.runningApp
                        let state=try await s.ping();self.updateRunning(state)
                        let running=self.runningApp=="trail-map" && state.flags&2==0
                        if running {
                            if previous != "trail-map" {self.lastMapCRC=nil;self.lastMapSource=nil;self.watchViewport=nil;self.watchCachedMap=nil;try await s.send(Data([84,77,1,0x13]));if self.apps.values.contains(where:{$0.name=="trail-map" && $0.version>=9}){try await s.send(Data([84,77,1,0x33]))}}
                            for _ in 0..<8 {guard let d=try? await s.recv(timeout:.milliseconds(20)) else{break};self.receiveMapMessage(d)}
                            if self.autoPhoneGPS && !self.watchGPSHasFix {model.location.start()}
                            self.sharingLocation=self.autoPhoneGPS && !self.watchGPSHasFix
                            try await self.sendCurrentLocation(model,over:s)
                            if self.apps.values.contains(where:{$0.name=="trail-map" && $0.version>=10}){
                                let places=model.saved.suffix(32).map{WatchPlace(x:Int32($0.point.x.rounded()),y:Int32($0.point.y.rounded()),name:$0.name)}
                                let crc=WireKit.crc32(try watchPlacesData(places));if self.lastPlacesCRC != crc || previous != "trail-map"{self.watchSavedPlaces=try await syncWatchPlaces(places,over:s,received:{[weak self] d in await self?.receiveMapMessage(d)});self.lastPlacesCRC=crc}
                            }
                            if self.autoMapSync {try await self.syncAreaIfNeeded(model,over:s)}
                        }else{self.sharingLocation=false;self.watchViewport=nil;self.watchGPSActive=false;self.watchGPSHasFix=false;self.watchSatellites=nil;self.lastPlacesCRC=nil;self.mapSyncStatus="Open Trail Map on your watch to sync"}
                    }catch {
                        if !Task.isCancelled {self.mapSyncStatus="Map sync will retry when the watch is ready"}
                    }
                    if generation==self.sessionGeneration {self.busy=false;if self.nativeMapRequested,self.runningApp=="trail-map",self.apps.values.contains(where:{$0.name=="trail-map" && $0.version>=9}),Date().timeIntervalSince(self.nativeMapAttempt)>15 {self.downloadWatchMap()}}
                }
                try? await Task.sleep(for:.seconds(self.runningApp=="trail-map" ? 1:8))
            }
        }
    }
    private func syncAreaIfNeeded(_ model:MapModel,over s:KSession) async throws {
        guard apps.values.contains(where:{$0.name=="trail-map" && $0.version>=6}) else{mapSyncStatus="Update Trail Map to keep complete map artwork while syncing";return}
        model.loadIfNeeded()
        let requestedViewport=watchViewport
        let point:MapPoint?,scale:Double,label:String
        if let viewport=requestedViewport {point=MapPoint(x:Double(viewport.x),y:Double(viewport.y));scale=Double(viewport.scale);label="Offline area"}
        else if model.scale<=60000 {point=model.center;scale=model.scale;label=model.selected?.name ?? "Offline area"}
        else if let fix=model.location.location {
            let p=MapModel.project(fix.coordinate)
            point=MapPoint(x:(p.x/500).rounded()*500,y:(p.y/500).rounded()*500);scale=8;label="Nearby offline area"
        }else if let saved=cachedSnapshot {point=MapPoint(x:Double(saved.centerX),y:Double(saved.centerY));scale=Double(saved.scale);label=saved.label}
        else{point=nil;scale=8;label="Offline area"}
        if let point,model.store != nil {
            let key="\(Int(point.x.rounded()))/\(Int(point.y.rounded()))/\(Int(scale.rounded()))/\(model.watchRevision)"
            if key != lastMapSource {
                do {
                    cachedSnapshot=try await model.makeWatchSnapshot(center:point,scale:scale,label:label)
                    cachedRaster=try await model.makeWatchRaster(center:point,scale:scale);lastMapSource=key
                    if let cachedSnapshot,let mapFile {try? cachedSnapshot.data.write(to:mapFile,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])}
                }catch {mapSyncStatus="No detailed map at this position; keeping the saved area";return}
            }
        }
        guard let cachedSnapshot else{mapSyncStatus="Choose a detailed area in Explore or enable location";return}
        let crc=WireKit.crc32(cachedSnapshot.data)^(cachedRaster.map{WireKit.crc32($0.data)} ?? 0)
        if let cachedRaster,watchCachedMap?.matches(cachedRaster)==true {
            lastMapCRC=crc;lastMapSuccess=Date();mapSyncStatus="Saved map ready on watch";status="Map ready on watch";return
        }
        let due=watchViewport != nil ? (crc != lastMapCRC && (lastMapAttempt.map{Date().timeIntervalSince($0)>=2} ?? true)):WatchMapSyncPolicy.shouldSend(changed:crc != lastMapCRC,running:true,sinceSuccess:lastMapSuccess.map{Date().timeIntervalSince($0)},sinceAttempt:lastMapAttempt.map{Date().timeIntervalSince($0)})
        guard due else{return}
        guard watchViewport==requestedViewport else{return}
        lastMapAttempt=Date();mapSyncStatus="Syncing offline area…"
        try await sendSnapshot(cachedSnapshot,over:s,id:UInt16.random(in:1...65535),progress:{_ in},received:{[weak self] d in await self?.receiveMapMessage(d)})
        guard watchViewport==requestedViewport else{return}
        if let cachedRaster {
            mapSyncStatus="Updating filled map and labels…"
            let completed=try await sendRaster(cachedRaster,over:s,id:UInt16.random(in:1...65535),received:{[weak self] d in await self?.receiveMapMessage(d)},checkpoint:{[weak self] in
                guard let self else{return false}
                return try await self.mapTransferCheckpoint(over:s,requested:requestedViewport,model:model)
            })
            guard completed else{self.mapSyncStatus="Updating latest map view…";return}
        }
        lastMapCRC=crc;lastMapSuccess=Date();mapSyncStatus="Map synced to watch";status="Map ready on watch"
    }
    private var locationSentAt:Date?
    private func sendCurrentLocation(_ model:MapModel,over s:KSession) async throws {
        guard autoPhoneGPS,!watchGPSHasFix,locationSentAt.map({Date().timeIntervalSince($0)>=3}) ?? true else{return}
        if let fix=model.location.location {
            let age=max(0,min(Double(UInt32.max),Date().timeIntervalSince(fix.timestamp)))
            let p=MapModel.project(fix.coordinate)
            try await s.send(phoneLocation(x:Int32(p.x.rounded()),y:Int32(p.y.rounded()),accuracy:UInt16(max(1,min(1000,fix.horizontalAccuracy.rounded()))),epoch:UInt32(max(0,min(Double(UInt32.max),fix.timestamp.timeIntervalSince1970))),age:UInt32(age),live:age<10))
        }else{try await s.send(Data([84,77,1,5]))}
        locationSentAt=Date()
    }
    private func mapTransferCheckpoint(over s:KSession,requested:WatchViewport?,model:MapModel) async throws ->Bool {
        for _ in 0..<8 {
            do {receiveMapMessage(try await s.recv(timeout:.milliseconds(1)))}
            catch WireError.timeout {break}
        }
        guard watchViewport==requested else{return false}
        if let cachedRaster,watchCachedMap?.matches(cachedRaster)==true {return false}
        try await sendCurrentLocation(model,over:s)
        return true
    }
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private static func describe(_ error:Error)->String {
        switch error {
        case WireError.noApp: return "Open Trail Map on the watch first."
        case WireError.timeout: return "The watch timed out. Keep the watch nearby and its Custom Apps menu closed during code uploads."
        case InstallError.busy: return "Close the running watch app and its Custom Apps menu, then retry."
        case InstallError.noFreeSlot: return "All eight watch app slots are full. Remove an app on the watch first."
        default:return error.localizedDescription
        }
    }


}

private enum WatchKeys {
    static func load(device:String)->Data? {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.cmf.watch-auth",kSecAttrAccount as String:device,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess else{return nil};return result as? Data
    }
    static func save(_ data:Data,device:String) {
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.cmf.watch-auth",kSecAttrAccount as String:device]
        SecItemDelete(q as CFDictionary)
        var insert=q;insert[kSecValueData as String]=data;insert[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary,nil)
    }
}
