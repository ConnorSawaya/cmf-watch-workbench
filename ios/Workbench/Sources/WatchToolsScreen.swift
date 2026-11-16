import CompanionCore
import SwiftUI
import UniformTypeIdentifiers

struct WatchToolsScreen: View {
  @EnvironmentObject var watch: WatchController
  @State private var importing = false
  @State private var pending: ValidatedPackage?
  var body: some View {
    List {
      Section {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("Custom apps").font(.title2.weight(.semibold))
            Text("Build something for your wrist.").foregroundStyle(.secondary)
          }
          Spacer()
          ConnectionPill()
        }.padding(.vertical, 10)
        if !watch.connected { Button("Connect watch") { watch.connect() }.disabled(watch.busy) }
      }
      Section("Examples") {
        if watch.availableAppPackages.isEmpty {
          Text("Build and verify the example packages, then stage them into this companion.")
            .foregroundStyle(.secondary)
        }
        ForEach(watch.availableAppPackages, id: \.name) { record in
          Button {
            watch.installBundled(record.name)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 5) {
                Text(record.name.capitalized).foregroundStyle(.primary)
                Text(description(record.name)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "arrow.down.circle")
            }
          }.disabled(!watch.connected || watch.busy)
        }
      }
      Section("On the watch") {
        if watch.apps.isEmpty {
          Text(watch.connected ? "No apps installed" : "Connect to read installed apps")
            .foregroundStyle(.secondary)
        }
        ForEach(watch.apps.keys.sorted(), id: \.self) { slot in
          if let app = watch.apps[slot] {
            LabeledContent(
              app.kind == 1 ? "App loader" : app.name.capitalized, value: "v\(app.version)")
          }
        }
        if let running = watch.runningApp { LabeledContent("Running", value: running) }
        Button("Refresh apps") { watch.refresh() }.disabled(!watch.connected || watch.busy)
      }
      Section("Developer") {
        Button("Import tested app package") { importing = true }.disabled(watch.busy)
        if let pending {
          LabeledContent(pending.header.name, value: "v\(pending.header.version)")
          Button("Install verified package") { watch.install(pending) }.disabled(
            !watch.connected || watch.busy)
        }
        Button("Install or update app loader") { watch.installBundled("loader") }.disabled(
          !watch.connected || watch.busy)
        Text(
          "New packages must match this build’s tested manifest. Build and test your app, stage its package, then rebuild this companion."
        ).font(.caption).foregroundStyle(.secondary)
        Link(
          "Write an app",
          destination: URL(
            string: "https://github.com/ConnorSawaya/cmf-watch-workbench/blob/main/docs/apps.md")!)
      }
      if watch.busy {
        Section {
          ProgressView(value: watch.progress)
          Text(watch.status).font(.caption)
        }
      }
      Section {
        Text(
          "Return the watch to its clock face and close Custom Apps before installing. Ordinary app updates use separate slots and do not reflash firmware."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }.navigationTitle("Apps").listStyle(.insetGrouped).scrollContentBackground(.hidden).background(
      Color.cmfPaper
    )
    .fileImporter(
      isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false
    ) { result in
      do {
        guard let url = try result.get().first else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 262208 else {
          throw TransferError.invalidPackage
        }
        pending = try watch.validateImported(Data(contentsOf: url))
      } catch { watch.message = error.localizedDescription }
    }
  }
  private func description(_ name: String) -> String {
    switch name {
    case "stopwatch": "Start, pause and record a lap"
    case "intervals": "Work, rest and repeat"
    case "counter": "A count that stays on the watch"
    default: "Install the reviewed package"
    }
  }
}
