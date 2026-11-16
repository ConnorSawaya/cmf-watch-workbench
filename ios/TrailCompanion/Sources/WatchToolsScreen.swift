import SwiftUI
import UniformTypeIdentifiers
import CompanionCore

struct WatchToolsScreen:View {
    @EnvironmentObject var watch:WatchController
    @EnvironmentObject var model:MapModel
    @State private var importing=false
    @State private var importingMap=false
    @State private var mapRevision=0
    @State private var pending:ValidatedPackage?
    var body:some View {
        List {
            Section {
                HStack(alignment:.top,spacing:16) {
                    Image(systemName:"map").font(.system(size:30,weight:.light)).foregroundStyle(Color.cmfOrange).frame(width:44,height:48)
                    VStack(alignment:.leading,spacing:7) {
                        Text("Trail Map").font(.title2.weight(.semibold))
                        Text("Offline maps for your chosen region. Drag to pan, zoom with the crown.").font(.subheadline).foregroundStyle(.secondary)
                        Label(watch.trailMapInstalled ? "Installed on watch":"Not installed",systemImage:watch.trailMapInstalled ? "checkmark.circle.fill":"arrow.down.circle").font(.caption).foregroundStyle(watch.trailMapInstalled ? Color.cmfGreen:.secondary)
                    }
                }.padding(.vertical,10)
                Button(watch.trailMapInstalled ? "Update Trail Map":"Install Trail Map") {watch.installWatchApps()}.disabled(!watch.connected || watch.busy)
            }
            if watch.waitingForWatchUpdate {
                Section {Label("Update ready",systemImage:"arrow.down.circle");Text("Return the watch to its clock face and close Custom Apps. The tested update will start automatically while this app stays open.").font(.subheadline);Button("Cancel update",role:.cancel) {watch.cancelQueuedWatchUpdate()}}
            }
            Section {NavigationLink("Organic Maps & saved places"){OrganicMapsScreen()};Text("Up to 32 saved places stay on the watch, separately from recent map views.").font(.caption).foregroundStyle(.secondary)}
            Section("Tools") {
                ForEach(watch.availableAppPackages,id:\.name){record in
                    Button(record.name.capitalized){watch.installBundled(record.name)}.disabled(!watch.connected || watch.busy)
                }
            }
            Section("Offline area") {
                if watch.watchOfflineMapBytes>0 {Label("Offline hiking map saved on watch",systemImage:"internaldrive.fill").font(.subheadline);Text("\(watch.watchMapTrailSegments.formatted()) mapped trail segments. Source records can overlap.").font(.caption).foregroundStyle(.secondary)}
                Button("Download \(MapAssets.watchName) · \(MapAssets.size(MapAssets.watchBytes))") {watch.downloadWatchMap()}.disabled(!watch.connected || watch.busy || !watch.trailMapInstalled)
                Button("Import watch map (.wp2map)"){importingMap=true}.disabled(watch.busy)
                Text("Choose a region that fits the available watch storage. Map files are checked before import. Keep Trail Map open during transfer; interrupted downloads resume.").font(.caption).foregroundStyle(.secondary)
                if watch.watchCacheAvailable {Label("Saved on watch: \(watch.savedMapViews) of 8 views",systemImage:"internaldrive").font(.subheadline)}
                if watch.watchCacheError != 0 {Text(watch.watchCacheError == -28 ? "Watch storage is low. Existing saved maps are kept.":"The watch could not save this area. Existing saved maps are kept.").font(.caption).foregroundStyle(.secondary)}
                Toggle("Auto-sync map area",isOn:$watch.autoMapSync)
                Text(watch.mapSyncStatus).font(.caption).foregroundStyle(.secondary)
                Button {model.activeTab=0} label:{Label("Choose area in Explore",systemImage:"map")}
                Button {watch.sendMap(model)} label:{Label("Send current area to watch",systemImage:"arrow.up.right.circle")}.disabled(!watch.connected || watch.busy || !watch.trailMapInstalled || model.store==nil)
                Text("Open Trail Map on the watch before sending. Eight recent map views are saved on the watch and replaced as you browse. Saved views work without the phone. Keep this app open for new areas.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {SatelliteSymbol().scaleEffect(0.7);Text(watch.watchSatellites.map(String.init) ?? "—");Spacer();Text(watch.watchGPSHasFix ? "Watch GPS fix":watch.watchGPSActive ? "Finding watch GPS":"Open Trail Map").font(.caption).foregroundStyle(.secondary)}
                Toggle("Phone location fallback",isOn:$watch.autoPhoneGPS)
                if watch.sharingLocation {Button("Stop sharing GPS",role:.destructive) {watch.stopLocation()}}
                else {Button {watch.startLocation(model.location)} label:{Label("Share iPhone GPS",systemImage:"location")}.disabled(!watch.connected || watch.busy || !watch.trailMapInstalled)}
            } header:{Text("Live location")} footer:{Text("Trail Map uses the watch's built-in GPS. Take it outdoors for its first fix. The satellite count comes from the watch. A last-known marker remains if the fix is lost.")}
            if watch.busy {
                Section {HStack(spacing:12) {ProgressView();Text(watch.status).font(.subheadline)};if let p=watch.progress {ProgressView(value:p);Text("\(Int(p*100))%").font(.caption.monospacedDigit());if watch.downloadingWatchMap {Text("\(ByteCountFormatter.string(fromByteCount:Int64(watch.watchMapDownloadBytes),countStyle:.decimal)) / \(MapAssets.size(MapAssets.watchBytes))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)}}}
            }
            Section("On your watch") {
                if watch.apps.isEmpty {Text(watch.connected ? "No apps installed":"Connect to view apps").foregroundStyle(.secondary)}
                ForEach(watch.apps.keys.sorted(),id:\.self) {slot in
                    if let app=watch.apps[slot] {LabeledContent(app.kind==1 ? "App launcher":app.name=="trail-map" ? "Trail Map":app.name,value:"v\(app.version)")}
                }
                if let name=watch.runningApp {LabeledContent("Running",value:name)}
                Button("Refresh apps") {watch.refresh()}.disabled(!watch.connected || watch.busy)
            }
            Section {
                DisclosureGroup("Developer tools") {
                    Button("Import tested app package") {importing=true}.disabled(watch.busy)
                    if let pending {
                        LabeledContent(pending.header.name,value:"v\(pending.header.version)")
                        Button("Install verified package") {watch.install(pending)}.disabled(!watch.connected || watch.busy)
                    }
                    Text("Only exact packages in this companion build's tested list can install. New code needs a tested build with an updated package manifest. App updates do not reflash the watch firmware.").font(.caption).foregroundStyle(.secondary)
                }
            } footer:{Text("Close Custom Apps before installing. Transfers are checked before completion; firmware and recovery tools are kept out of normal app updates.")}
        }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.cmfPaper).navigationTitle("Watch apps")
        .fileImporter(isPresented:$importingMap,allowedContentTypes:[.data]){result in
            if case .success(let url)=result{Task{do{try await Task.detached(priority:.userInitiated){try MapAssets.importWatch(url)}.value;mapRevision+=1}catch{watch.message=error.localizedDescription}}}
        }
        .id(mapRevision)
        .fileImporter(isPresented:$importing,allowedContentTypes:[.data],allowsMultipleSelection:false) {result in
            do {
                guard let url=try result.get().first else{return}
                let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
                let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
                guard let size=attrs[.size] as? NSNumber,size.intValue<=262208 else {throw TransferError.invalidPackage}
                pending=try watch.validateImported(Data(contentsOf:url,options:.mappedIfSafe))
            }catch {watch.message=error.localizedDescription}
        }
    }
}
