import Combine
import CompanionCore
import CryptoKit
import Foundation
import Security
import UIKit
import WireKit

@MainActor final class WatchController: ObservableObject {
  @Published var status = "Ready to connect"
  @Published var name = "CMF Watch Pro 2"
  @Published var battery: Int?
  @Published var batteryCharging = false
  @Published var batteryUpdated: Date?
  @Published var connected = false
  @Published var busy = false
  @Published var progress: Double?
  @Published var message: String?
  @Published var apps: [Int: PackageHeader] = [:]
  @Published var stockPaired = false
  @Published var firmwareVersion: String? = UserDefaults.standard.string(forKey: "watch-firmware") {
    didSet {
      if let firmwareVersion {
        UserDefaults.standard.set(firmwareVersion, forKey: "watch-firmware")
      }
    }
  }
  @Published var pairingHint: String?
  @Published var featureStatus = "Changes are confirmed by the watch before being marked saved."
  @Published var loaderVerified = UserDefaults.standard.bool(forKey: "loader-verified")
  @Published var standardFeaturesEnabled = UserDefaults.standard.bool(
    forKey: "stock-features-enabled")
  @Published var runningApp: String?
  private var foreground = true
  private var lastClockUptime: TimeInterval?
  private var stock: StockConnection?
  private var pairingRequested = false
  private var setupStandardRequested = CommandLine.arguments.contains("-setup-standard-controls")
  @Published var faces = FaceLibrary.load()
  @Published var faceStatus = ""
  func saveFace(_ file: FaceFile) {
    do {
      _ = try FaceLibrary.add(file)
      faces = FaceLibrary.load()
      faceStatus = "Face saved on this phone"
    } catch { message = error.localizedDescription }
  }
  func faceIsInstalled(_ face: SavedFace) -> Bool {
    face.dialID != nil && face.installedDevice == ble?.identifier
  }
  func deleteLocalFace(_ face: SavedFace) {
    do {
      let kept = faces.filter { $0.id != face.id }
      try FaceLibrary.save(kept)
      try? FileManager.default.removeItem(at: face.file)
      try? FileManager.default.removeItem(at: face.thumbnail)
      faces = kept
    } catch { message = error.localizedDescription }
  }
  func installFace(_ face: SavedFace) {
    guard !faceIsInstalled(face) else { return }
    guard runningApp == nil else {
      message = "Close the custom app on the watch before installing a face."
      return
    }
    guard let device = ble?.identifier else {
      message = "Connect the watch before installing a face."
      return
    }
    stockOperation("Installing watch face…") { s in
      let file = try FaceFile(Data(contentsOf: face.file))
      let id =
        (face.pendingDevice == device ? face.pendingDialID : nil)
        ?? UInt32.random(in: 10000..<0x7fff_ffff)
      var pending = self.faces
      if let i = pending.firstIndex(where: { $0.id == face.id }) {
        pending[i].pendingDialID = id
        pending[i].pendingDevice = device
      }
      try FaceLibrary.save(pending)
      self.faces = pending
      UIApplication.shared.isIdleTimerDisabled = true
      defer { UIApplication.shared.isIdleTimerDisabled = false }
      try await s.uploadFace(
        file, id: id,
        progress: { n in
          await MainActor.run {
            self.progress = Double(n) / Double(file.data.count)
            self.faceStatus =
              n == file.data.count
              ? "Activating face…"
              : "Sending face: \(n.formatted()) / \(file.data.count.formatted()) bytes"
          }
        })
      var list = self.faces
      if let i = list.firstIndex(where: { $0.id == face.id }) {
        list[i].dialID = id
        list[i].installedDevice = device
        list[i].pendingDialID = nil
        list[i].pendingDevice = nil
      }
      try FaceLibrary.save(list)
      self.faces = list
      self.faceStatus = "Watch confirmed the face is active"
    }
  }
  func removeFace(_ face: SavedFace) {
    guard runningApp == nil, faceIsInstalled(face), let id = face.dialID else { return }
    stockOperation("Removing watch face…") { s in
      let file = try FaceFile(Data(contentsOf: face.file))
      try await s.uploadFace(file, id: id, delete: true)
      var list = self.faces
      if let i = list.firstIndex(where: { $0.id == face.id }) {
        list[i].dialID = nil
        list[i].installedDevice = nil
      }
      try FaceLibrary.save(list)
      self.faces = list
      self.faceStatus = "Watch confirmed the face was removed"
    }
  }
  @Published var firmwareStatus = "Loader firmware has not been checked"
  private var ble: WatchBLE?
  private var session: KSession?
  private var operation: Task<Void, Never>?
  private var sessionGeneration = 0
  private var lastDiagnosticProgress = Date.distantPast
  init() {
    if CommandLine.arguments.contains("-export-test-face"),
      let file = try? FaceArtwork.make(name: "Workbench", accent: .white, rounded: true, photo: nil)
    {
      try? FaceLibrary.add(file)
      faces = FaceLibrary.load()
    }
    if let i = CommandLine.arguments.firstIndex(of: "-watch-suffix"),
      i + 1 < CommandLine.arguments.count
    {
      let suffix = CommandLine.arguments[i + 1].uppercased()
      if suffix.count == 4,
        suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) })
      {
        pairingHint = suffix
      }
    }
    if CommandLine.arguments.contains("-pair-reset") {
      DispatchQueue.main.async { self.pairResetWatch() }
    } else if CommandLine.arguments.contains("-connect-watch")
      || (standardFeaturesEnabled
        && UserDefaults.standard.object(forKey: "watch-auto-connect") as? Bool != false)
    {
      DispatchQueue.main.async { self.connect() }
    }
  }
  func acceptQR(_ raw: String) {
    do {
      let code = try WatchPairingCode(raw)
      pairingHint = code.suffix
      status = "Watch QR recognized. Ready to pair."
    } catch { message = "This QR code is not a supported CMF Watch setup code." }
  }
  func pairResetWatch() {
    pairingRequested = true
    connect()
  }
  func connect() {
    UserDefaults.standard.set(true, forKey: "watch-auto-connect")
    if ble == nil {
      let b = WatchBLE()
      b.onState = { [weak self] state in self?.stateChanged(state) }
      b.onName = { [weak self] in self?.name = $0 }
      ble = b
    }
    ble?.desiredSuffix = pairingHint
    ble?.connect()
  }
  func disconnect() {
    UserDefaults.standard.set(false, forKey: "watch-auto-connect")
    if let session { Task { await session.close() } }
    operation?.cancel()
    sessionGeneration += 1
    session = nil
    stockPaired = false
    connected = false
    runningApp = nil
    busy = false
    progress = nil
    ble?.disconnect()
  }
  private func stateChanged(_ state: WatchBLE.State) {
    switch state {
    case .off:
      status = "Turn on Bluetooth and allow access in Settings"
      connected = false
    case .searching: status = "Searching for Watch Pro 2…"
    case .connecting: status = "Connecting…"
    case .disconnected:
      operation?.cancel()
      busy = false
      progress = nil
      status = "Disconnected"
      session = nil
      stockPaired = false
      connected = false
      runningApp = nil
      sessionGeneration += 1
    case .failed(let reason):
      status = reason
      connected = false
    case .ready:
      operation?.cancel()
      sessionGeneration += 1
      let generation = sessionGeneration
      operation = Task {
        guard let ble else { return }
        busy = true
        defer { if generation == sessionGeneration { busy = false } }
        do {
          if pairingRequested {
            status = "Pairing reset watch…"
            let fresh = StockConnection(link: ble)
            await fresh.attach()
            let auth = try await fresh.pair()
            if let identifier = ble.identifier { WatchKeys.save(auth, device: identifier) }
            stock = fresh
            stockPaired = true
            firmwareVersion = try? await fresh.readVersion()
            pairingRequested = false
            status = "Paired to stock watch"
            firmwareStatus = "Ready for the initial loader firmware update"
            message =
              "Bluetooth pairing completed. Install the initial loader patch separately to enable custom apps."
            return
          }
          status = "Checking app loader…"
          let (s, _) = try await KSession.open(link: ble)
          guard generation == sessionGeneration else { return }
          session = s
          connected = true
          loaderVerified = true
          UserDefaults.standard.set(true, forKey: "loader-verified")
          status = "Watch connected"
          firmwareStatus = "Custom app channel is responding"
          apps = try await WireKit.installed(s)
          updateRunning(try await s.ping())
          if setupStandardRequested {
            setupStandardRequested = false
            DispatchQueue.main.async { self.setupStandardFeatures() }
          } else if standardFeaturesEnabled {
            DispatchQueue.main.async { self.refreshBattery() }
          }
        } catch {
          guard generation == sessionGeneration else { return }
          if let id = ble.identifier, let auth = WatchKeys.load(device: id) {
            let resumed = StockConnection(link: ble)
            await resumed.attach()
            do {
              try await resumed.resume(auth: auth)
              stock = resumed
              stockPaired = true
              firmwareVersion = try? await resumed.readVersion()
              status = "Paired to stock watch"
              firmwareStatus = "Ready for the initial loader firmware update"
              return
            } catch { await resumed.close() }
          }
          status = "Watch connected; custom loader did not respond"
          firmwareStatus =
            "The initial loader firmware must be installed first. This build does not flash firmware automatically."
          message =
            "The watch did not answer the custom app protocol. Stock firmware needs the initial loader patch; a Bluetooth connection alone cannot install code."
        }
      }
    }
  }
  func refresh() {
    guard let s = session, !busy else { return }
    run {
      self.apps = try await WireKit.installed(s)
      self.updateRunning(try await s.ping())
      self.status = "Watch apps refreshed"
    }
  }
  private func testedPackage(_ package: ValidatedPackage) throws {
    guard let url = Bundle.main.url(forResource: "tested-packages", withExtension: "json"),
      let record = try JSONDecoder().decode([TestedPackage].self, from: Data(contentsOf: url))
        .first(where: { $0.name == package.header.name && $0.kind == package.header.kind })
    else { throw CompanionPolicyError.untestedPackage }
    try record.verify(package)
  }
  func validateImported(_ data: Data) throws -> ValidatedPackage {
    let package = try ValidatedPackage(data)
    try testedPackage(package)
    return package
  }
  private func preflightInstall() async throws -> KSession {
    guard let initial = session else { throw WireError.closed }
    let state = try await initial.ping()
    updateRunning(state)
    guard state.slot == 255 else { throw CompanionPolicyError.closeWatchApp }
    try await performStock("Checking watch battery…") { s in
      self.acceptBattery(try await s.readBattery())
      self.firmwareVersion = try await s.readVersion()
    }
    guard let current = session else { throw WireError.closed }
    let live = try await current.ping()
    updateRunning(live)
    try CompanionPolicy.validateInstall(
      firmware: firmwareVersion, battery: battery,
      batteryAge: batteryUpdated.map { Date().timeIntervalSince($0) }, runningSlot: live.slot)
    return current
  }
  private func confirmedInstall(
    _ package: ValidatedPackage, over s: KSession, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    try testedPackage(package)
    let slot = try await WireKit.install(s, package: package.data, progress: progress)
    apps = try await WireKit.installed(s)
    guard apps[slot] == package.header else { throw TransferError.noAcknowledgement }
  }
  func install(_ package: ValidatedPackage) {
    guard session != nil, !busy else { return }
    do { try testedPackage(package) } catch {
      message = error.localizedDescription
      return
    }
    run {
      let s = try await self.preflightInstall()
      UIApplication.shared.isIdleTimerDisabled = true
      defer { UIApplication.shared.isIdleTimerDisabled = false }
      self.status = "Installing \(package.header.name)…"
      self.progress = 0
      try await self.confirmedInstall(package, over: s) { p in
        Task { @MainActor in self.progress = p }
      }
      self.status = "\(package.header.name) installed"
      self.message =
        "Installed and confirmed by your watch. Open Custom Apps → \(package.header.name) on the watch."
    }
  }
  var availableAppPackages: [TestedPackage] {
    guard let url = Bundle.main.url(forResource: "tested-packages", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let records = try? JSONDecoder().decode([TestedPackage].self, from: data)
    else { return [] }
    return records.filter { $0.kind == 0 }
  }
  func installBundled(_ name: String) {
    do {
      guard let url = Bundle.main.url(forResource: name, withExtension: "wp2app") else {
        throw TransferError.invalidPackage
      }
      install(try ValidatedPackage(Data(contentsOf: url)))
    } catch { message = error.localizedDescription }
  }
  func refreshBattery() {
    stockOperation("Reading watch battery…") { s in
      self.acceptBattery(try await s.readBattery())
      self.featureStatus = "Battery read directly from watch"
    }
  }
  private func acceptBattery(_ value: WatchBattery) {
    battery = value.percent
    batteryCharging = value.charging
    batteryUpdated = Date()
  }
  func setupStandardFeatures() {
    stockOperation("Setting watch clock…", initialize: true) { s in
      self.firmwareVersion = try? await s.readVersion()
      self.acceptBattery(try await s.readBattery())
      self.standardFeaturesEnabled = true
      UserDefaults.standard.set(true, forKey: "stock-features-enabled")
      self.featureStatus = "Clock sync completed; standard watch connection verified."
    }
  }
  private func stockOperation(
    _ title: String, initialize: Bool = false, quiet: Bool = false,
    _ work: @escaping @MainActor (StockConnection) async throws -> Void
  ) {
    guard connected || stockPaired, ble != nil else {
      if !quiet { message = "Connect your watch first." }
      return
    }
    guard !busy else { return }
    run(quiet: quiet) { try await self.performStock(title, initialize: initialize, work) }
  }
  private func performStock(
    _ title: String, initialize: Bool = false,
    _ work: @escaping @MainActor (StockConnection) async throws -> Void
  ) async throws {
    guard let ble else { throw WireError.closed }
    let generation = sessionGeneration
    if let session { await session.close() }
    session = nil
    let s = StockConnection(link: ble)
    await s.attach()
    var failure: Error?
    do {
      guard let id = ble.identifier, let auth = WatchKeys.load(device: id) else {
        throw PairingError.invalidChallenge
      }
      status = title
      try await s.resume(auth: auth)
      guard standardFeaturesEnabled || initialize else {
        throw StockFeatureError.clockSetupRequired
      }
      let now = Date()
      let offset = TimeZone.current.secondsFromGMT(for: Date())
      let previous = UserDefaults.standard.object(forKey: "watch-clock-epoch") as? Double
      let previousOffset = UserDefaults.standard.object(forKey: "watch-clock-offset") as? Int
      try CompanionPolicy.validateClock(
        epoch: now.timeIntervalSince1970, offset: offset, lastEpoch: previous,
        lastOffset: previousOffset,
        elapsed: lastClockUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
      try await s.initializeClock(
        epoch: UInt32(now.timeIntervalSince1970), offsetMilliseconds: Int32(offset * 1000))
      UserDefaults.standard.set(now.timeIntervalSince1970, forKey: "watch-clock-epoch")
      UserDefaults.standard.set(offset, forKey: "watch-clock-offset")
      lastClockUptime = ProcessInfo.processInfo.systemUptime
      try await work(s)
    } catch { failure = error }
    await s.close()
    guard generation == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
    if let (new, _) = try? await KSession.open(link: ble) {
      session = new
      connected = true
      updateRunning(try await new.ping())
    } else {
      connected = false
    }
    if let failure {
      featureStatus = "Sync or change could not be confirmed. \(failure.localizedDescription)"
      throw failure
    }
    status = "Watch connected"
  }
  private func updateRunning(_ state: (slot: UInt8, flags: UInt8)) {
    runningApp = state.slot == 255 ? nil : apps[Int(state.slot)]?.name ?? "Watch app"
  }
  private func run(quiet: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    let generation = sessionGeneration
    operation = Task {
      defer {
        if generation == sessionGeneration {
          busy = false
          progress = nil
        }
      }
      do { try await body() } catch {
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        status = "Operation stopped: \(Self.describe(error))"
        if !quiet { message = Self.describe(error) }
      }
    }
  }
  func setForeground(_ active: Bool) {
    foreground = active
    guard active else { return }
    if connected, !busy, runningApp == nil, standardFeaturesEnabled,
      batteryUpdated.map({ Date().timeIntervalSince($0) > 300 }) ?? true
    {
      refreshBattery()
    } else if !connected, standardFeaturesEnabled,
      UserDefaults.standard.object(forKey: "watch-auto-connect") as? Bool != false
    {
      connect()
    }
  }
  private static func describe(_ error: Error) -> String {
    switch error {
    case WireError.noApp: return "Open a custom app on the watch first."
    case WireError.timeout:
      return
        "The watch timed out. Keep the watch nearby and its Custom Apps menu closed during code uploads."
    case InstallError.busy:
      return "Close the running watch app and its Custom Apps menu, then retry."
    case InstallError.noFreeSlot:
      return "All eight watch app slots are full. Remove an app on the watch first."
    default: return error.localizedDescription
    }
  }

}

private enum WatchKeys {
  static func load(device: String) -> Data? {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "local.cmf.watch-auth", kSecAttrAccount as String: device,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }
  static func save(_ data: Data, device: String) {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "local.cmf.watch-auth", kSecAttrAccount as String: device,
    ]
    SecItemDelete(q as CFDictionary)
    var insert = q
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(insert as CFDictionary, nil)
  }
}
