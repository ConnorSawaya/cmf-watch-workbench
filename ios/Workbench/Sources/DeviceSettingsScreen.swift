import CompanionCore
import SwiftUI

struct SettingsScreen: View {
  @EnvironmentObject var watch: WatchController
  @State private var scanning = false
  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            VStack(alignment: .leading, spacing: 6) {
              Text(watch.name).font(.title2.weight(.semibold))
              Text("Custom app workbench").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ConnectionPill()
          }.padding(.vertical, 10)
          LabeledContent(
            "Battery",
            value: watch.battery.map { "\($0)%" + (watch.batteryCharging ? " · Charging" : "") }
              ?? "Not read")
          LabeledContent("Firmware", value: watch.firmwareVersion ?? "Not read")
          LabeledContent(
            "Custom app channel", value: watch.connected ? "Responding" : "Not connected")
          Text(watch.status).font(.caption).foregroundStyle(.secondary)
        }
        Section {
          if watch.connected || watch.stockPaired {
            Button("Disconnect watch") { watch.disconnect() }
          } else {
            Button("Connect watch") { watch.connect() }
          }
          Button("Read battery") { watch.refreshBattery() }.disabled(
            !(watch.connected || watch.stockPaired))
          NavigationLink {
            WatchFacesScreen()
          } label: {
            FeatureRow(
              title: "Watch faces", subtitle: "Create, import and install your own faces",
              icon: "applewatch.watchface")
          }
        }.disabled(watch.busy)
        Section("Pairing") {
          Button("Scan watch QR code") { scanning = true }
          Button("Pair reset watch") { watch.pairResetWatch() }
          if let hint = watch.pairingHint { LabeledContent("Pairing filter", value: hint) }
          Text(
            "Use reset pairing when the watch is showing its initial setup screen. Pairing and installing the initial app-loader patch are separate steps."
          ).font(.caption).foregroundStyle(.secondary)
        }.disabled(watch.busy)
        Section("Clock") {
          Button("Sync clock & enable standard controls") { watch.setupStandardFeatures() }
            .disabled(watch.busy || !(watch.connected || watch.stockPaired))
          Text(
            "Initialize a reset clock showing January 1, or sync when the watch already shows the correct date. Large backward clock corrections can trigger stock recovery."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Build on this") {
          Text(
            "This is a base companion for pairing, device status, reviewed custom apps and watch faces. Add your own app-specific screens and messages using the SDK."
          ).foregroundStyle(.secondary)
          Link(
            "Install and build guide",
            destination: URL(
              string:
                "https://github.com/ConnorSawaya/cmf-watch-workbench/blob/main/docs/getting-started.md"
            )!)
          Text("Watch Pro 2 · JX402 / D398 · 1.0.0.73").font(.caption).foregroundStyle(.secondary)
        }
        FeatureFeedback()
      }.navigationTitle("Watch").listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .background(Color.cmfPaper)
        .sheet(isPresented: $scanning) {
          NavigationStack {
            WatchQRScanner { result in
              scanning = false
              switch result {
              case .success(let value): watch.acceptQR(value)
              case .failure(let error): watch.message = error.localizedDescription
              }
            }.navigationTitle("Scan watch QR").toolbar { Button("Cancel") { scanning = false } }
          }
        }
    }
  }
}
