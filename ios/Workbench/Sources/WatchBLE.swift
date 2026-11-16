@preconcurrency import CoreBluetooth
import Foundation
import UIKit
import WireKit
import CompanionCore

// CoreBluetooth transport based on cmf-tech-community/wp2-apps (MIT); see THIRD_PARTY.md.
final class WatchBLE:NSObject,Link,@unchecked Sendable {
    enum State {case off,searching,connecting,ready,disconnected,failed(String)}
    static let command=CBUUID(string:"FFF0")
    static let shell=CBUUID(string:"77D4E67C-2FE2-2334-0D35-9CCD078F529C")
    static let bulk=CBUUID(string:"02F00000-0000-0000-0000-00000000FFE0")
    private let subscriptions=[CBUUID(string:Uuid.cmdNotify),CBUUID(string:Uuid.shellNotify),CBUUID(string:"02F00000-0000-0000-0000-00000000FFE2")]
    private var central:CBCentralManager!
    private var device:CBPeripheral?
    private var chars:[CBUUID:CBCharacteristic]=[:]
    private var handler:(@Sendable(String,Data)->Void)?
    private var writeContinuation:CheckedContinuation<Void,Error>?
    private var writeID=UUID()
    private var bulkID=UUID()
    private var bulkWrite:(CBCharacteristic,[Data],Int,CheckedContinuation<Void,Error>)?
    private var timer:DispatchWorkItem?
    private var wanted=false
    private var ready=false
    var desiredSuffix:String?
    var onState:((State)->Void)?
    var onName:((String)->Void)?
    var onBattery:((Int)->Void)?
    var identifier:String? {device?.identifier.uuidString}
    override init() {super.init();central=CBCentralManager(delegate:self,queue:.main,options:[CBCentralManagerOptionRestoreIdentifierKey:"local.cmf.watch.central"])}
    func connect() {wanted=true;find()}
    func disconnect() {
        wanted=false;timer?.cancel();central.stopScan()
        if let p=device {central.cancelPeripheralConnection(p)}
        device=nil;ready=false;failWrite(WireError.closed);onState?(.disconnected)
    }
    func onNotify(_ handler:@escaping @Sendable(String,Data)->Void) {DispatchQueue.main.async {self.handler=handler}}
    func write(_ uuid:String,_ data:Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in
            DispatchQueue.main.async {
                guard let p=self.device,p.state == .connected,let ch=self.chars[CBUUID(string:uuid)],self.writeContinuation==nil,
                      ch.properties.contains(.write),data.count<=p.maximumWriteValueLength(for:.withResponse) else {c.resume(throwing:WireError.closed);return}
                let id=UUID();self.writeID=id;self.writeContinuation=c
                p.writeValue(data,for:ch,type:.withResponse)
                DispatchQueue.main.asyncAfter(deadline:.now()+10) {
                    if self.writeID==id && self.writeContinuation != nil {self.failWrite(WireError.timeout("Bluetooth write"));self.disconnect()}
                }
            }
        }
    }
    func writeWithoutResponse(_ uuid:String,_ data:Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            DispatchQueue.main.async {
                guard let p=self.device,p.state == .connected,let ch=self.chars[CBUUID(string:uuid)],ch.properties.contains(.writeWithoutResponse),self.bulkWrite==nil else{continuation.resume(throwing:WireError.closed);return}
                let maximum=p.maximumWriteValueLength(for:.withoutResponse);guard maximum>0 else{continuation.resume(throwing:WireError.closed);return}
                let pieces=stride(from:0,to:data.count,by:maximum).map{Data(data[$0..<min($0+maximum,data.count)])}
                let id=UUID();self.bulkID=id;self.bulkWrite=(ch,pieces,0,continuation);self.pumpBulk()
                DispatchQueue.main.asyncAfter(deadline:.now()+10){if self.bulkID==id && self.bulkWrite != nil{self.failWrite(WireError.timeout("Watch-face write"));self.disconnect()}}
            }
        }
    }
    private func pumpBulk(){
        guard let p=device else{return}
        while let (ch,pieces,index,c)=bulkWrite,p.canSendWriteWithoutResponse {
            if index==pieces.count{bulkWrite=nil;c.resume();return}
            p.writeValue(pieces[index],for:ch,type:.withoutResponse);bulkWrite=(ch,pieces,index+1,c)
        }
        if let (_,pieces,index,c)=bulkWrite,index==pieces.count{bulkWrite=nil;c.resume()}
    }
    private func failWrite(_ error:Error) {let c=writeContinuation;writeContinuation=nil;c?.resume(throwing:error);let b=bulkWrite;bulkWrite=nil;b?.3.resume(throwing:error)}
    private func matches(_ name:String)->Bool {name.lowercased().contains("watch pro 2") && (desiredSuffix==nil || name.uppercased().hasSuffix(desiredSuffix!))}
    private func find() {
        guard device?.state != .connecting,!(device?.state == .connected && ready) else{return}
        guard wanted,central.state == .poweredOn else {if wanted {onState?(.off)};return}
        if let raw=UserDefaults.standard.string(forKey:"watch-peripheral"),let id=UUID(uuidString:raw),let p=central.retrievePeripherals(withIdentifiers:[id]).first {attach(p);return}
        if let p=central.retrieveConnectedPeripherals(withServices:[Self.command]).first(where:{self.matches($0.name ?? "")}) {attach(p);return}
        onState?(.searching);central.scanForPeripherals(withServices:UIApplication.shared.applicationState == .active ? nil:[Self.command],options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
        timer?.cancel();let t=DispatchWorkItem { [weak self] in self?.central.stopScan();self?.onState?(.failed("Watch not found. Keep it nearby and retry.")) };timer=t
        DispatchQueue.main.asyncAfter(deadline:.now()+20,execute:t)
    }
    private func attach(_ p:CBPeripheral) {
        timer?.cancel();central.stopScan();device=p;p.delegate=self;onName?(p.name ?? "CMF Watch Pro 2");onState?(.connecting)
        if p.state == .connected {discover(p)}else{central.connect(p)}
    }
    private func discover(_ p:CBPeripheral) {chars=[:];ready=false;p.discoverServices(nil)}
    private func checkReady() {
        guard !ready,subscriptions.allSatisfy({chars[$0]?.isNotifying==true}),chars[CBUUID(string:Uuid.cmdWrite)] != nil,chars[CBUUID(string:Uuid.shellWrite)] != nil else{return}
        ready=true;if let id=device?.identifier {UserDefaults.standard.set(id.uuidString,forKey:"watch-peripheral")};DispatchQueue.main.asyncAfter(deadline:.now()+0.6) {if self.wanted,self.device?.state == .connected {self.onState?(.ready)}}
    }
}
extension WatchBLE:CBCentralManagerDelegate {
    func centralManager(_ c:CBCentralManager,willRestoreState state:[String:Any]) {
        guard UserDefaults.standard.object(forKey:"watch-auto-connect") as? Bool != false,
              let restored=(state[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else{return}
        UserDefaults.standard.set(restored.identifier.uuidString,forKey:"watch-peripheral");wanted=true
    }
    func centralManagerDidUpdateState(_ c:CBCentralManager) {if c.state == .poweredOn {find()}else{onState?(.off);failWrite(WireError.closed)}}
    func centralManager(_ c:CBCentralManager,didDiscover p:CBPeripheral,advertisementData:[String:Any],rssi:NSNumber) {
        let name=(advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        if matches(name) {attach(p)}
    }
    func centralManager(_ c:CBCentralManager,didConnect p:CBPeripheral) {discover(p)}
    func centralManager(_ c:CBCentralManager,didFailToConnect p:CBPeripheral,error:Error?) {device=nil;onState?(.failed("Could not connect to the watch."))}
    func centralManager(_ c:CBCentralManager,didDisconnectPeripheral p:CBPeripheral,error:Error?) {
        failWrite(WireError.closed);ready=false;device=nil;onState?(.disconnected)
        if wanted {DispatchQueue.main.asyncAfter(deadline:.now()+3){self.find()}}
    }
}
extension WatchBLE:CBPeripheralDelegate {
    func peripheralIsReady(toSendWriteWithoutResponse peripheral:CBPeripheral){pumpBulk()}
    func peripheral(_ p:CBPeripheral,didDiscoverServices error:Error?) {
        if error != nil {onState?(.failed("Watch service discovery failed."));return}
        p.services?.forEach {p.discoverCharacteristics(nil,for:$0)}
    }
    func peripheral(_ p:CBPeripheral,didDiscoverCharacteristicsFor s:CBService,error:Error?) {
        if error != nil {onState?(.failed("Watch characteristic discovery failed."));return}
        for ch in s.characteristics ?? [] {chars[ch.uuid]=ch;if subscriptions.contains(ch.uuid) || ch.uuid==CBUUID(string:CompanionCore.StockConnection.otaNotify) {p.setNotifyValue(true,for:ch)};if ch.uuid==CBUUID(string:"2A19"),ch.properties.contains(.read) {p.readValue(for:ch)}}
        checkReady()
    }
    func peripheral(_ p:CBPeripheral,didUpdateNotificationStateFor ch:CBCharacteristic,error:Error?) {if error != nil {onState?(.failed("Could not subscribe to watch messages."))}else{checkReady()}}
    func peripheral(_ p:CBPeripheral,didUpdateValueFor ch:CBCharacteristic,error:Error?) {
        guard error==nil,let value=ch.value else{return}
        if ch.uuid==CBUUID(string:"2A19"),let n=value.first,n<=100 {onBattery?(Int(n));return}
        let id=ch.uuid.uuidString.count==4 ? "0000\(ch.uuid.uuidString)-0000-1000-8000-00805F9B34FB":ch.uuid.uuidString
        handler?(id,value)
    }
    func peripheral(_ p:CBPeripheral,didWriteValueFor ch:CBCharacteristic,error:Error?) {let c=writeContinuation;writeContinuation=nil;if let error{c?.resume(throwing:error)}else{c?.resume()}}
}
