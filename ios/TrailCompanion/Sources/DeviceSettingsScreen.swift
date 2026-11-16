import SwiftUI
import CompanionCore

struct SettingsScreen:View {
    @EnvironmentObject var watch:WatchController
    var body:some View {
        NavigationStack {
            List {
                Section {
                    HStack {VStack(alignment:.leading,spacing:7) {Text("Watch Pro 2").font(.title2.weight(.semibold));Text(watch.loaderVerified ? "Custom apps enabled":"Ready to pair").font(.caption).foregroundStyle(.secondary)};Spacer();ConnectionPill()}.padding(.vertical,12)
                    if watch.connected || watch.stockPaired {Button("Disconnect watch") {watch.disconnect()}.disabled(watch.busy)}else{Button("Connect watch") {watch.connect()}.disabled(watch.busy)}
                    Button("Refresh battery") {watch.refreshBattery()}.disabled(watch.busy || !watch.connected)
                }
                Section("Everyday") {
                    NavigationLink {WatchFacesScreen()} label:{FeatureRow(title:"Watch faces",subtitle:"Create, import and install your own faces",icon:"applewatch.watchface")}
                    NavigationLink {AlarmsScreen()} label:{FeatureRow(title:"Alarms",subtitle:"Times and repeat days",icon:"alarm")}
                    NavigationLink {ReminderScreen(ability:0x60,title:"Stand reminders")} label:{FeatureRow(title:"Stand reminders",subtitle:"Interval and quiet hours",icon:"figure.stand")}
                    NavigationLink {ReminderScreen(ability:0x61,title:"Water reminders")} label:{FeatureRow(title:"Water reminders",subtitle:"Interval and quiet hours",icon:"drop")}
                    NavigationLink {ContactsScreen()} label:{FeatureRow(title:"Frequent contacts",subtitle:"Up to 20 contacts on the watch",icon:"person.crop.circle")}
                }
                if !watch.standardFeaturesEnabled {
                    Section("Finish watch setup") {
                        Text("Standard controls need the watch's clock to be initialized. Use this for the reset clock showing January 1, or when its date and time already match this iPhone.").font(.subheadline)
                        Button("Sync clock & enable standard controls") {watch.setupStandardFeatures()}.disabled(watch.busy || !watch.connected)
                        Text("A backward correction of more than two minutes can trigger the watch's factory recovery. Check the displayed date before syncing.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Preferences") {
                    NavigationLink {WatchPreferencesScreen()} label:{FeatureRow(title:"Display & units",subtitle:"Wrist wake, time format and units",icon:"sun.max")}
                    NavigationLink {MonitoringScreen()} label:{FeatureRow(title:"Health monitoring",subtitle:"Heart rate, oxygen and stress",icon:"heart.text.clipboard")}
                    NavigationLink {GoalsScreen()} label:{FeatureRow(title:"Daily goals",subtitle:"Steps, distance and active calories",icon:"scope")}
                    NavigationLink {WatchProfileScreen()} label:{FeatureRow(title:"Personal profile",subtitle:"Activity calculation settings",icon:"person")}
                }
                Section("Connection") {
                    NavigationLink {StockFeatureGuide()} label:{FeatureRow(title:"Notifications & calls",subtitle:"Setup and feature availability",icon:"bell")}
                    Button {watch.applySetting(.findWatch(true))} label:{FeatureRow(title:"Find my watch",subtitle:"Ring and vibrate nearby",icon:"wave.3.right")}.disabled(watch.busy || !watch.connected)
                    Button("Stop ringing") {watch.applySetting(.findWatch(false))}.disabled(watch.busy || !watch.connected)
                }
                Section("Maps & apps") {
                    NavigationLink {WatchToolsScreen()} label:{FeatureRow(title:"Watch apps & map transfer",subtitle:"Install code and send an offline area",icon:"square.grid.2x2")}
                    NavigationLink {MapSettingsScreen()} label:{FeatureRow(title:"Offline map storage",subtitle:"Import and manage your regions",icon:"externaldrive")}
                    NavigationLink {ConnectionSetupScreen()} label:{FeatureRow(title:"Pairing & device information",subtitle:"QR setup and firmware status",icon:"qrcode.viewfinder")}
                }
                FeatureFeedback()
                Section("Sync") {
                    Toggle("Automatic sync",isOn:$watch.autoSync)
                    LabeledContent("Last synced",value:watch.health.syncedAt.map{$0.formatted(date:.abbreviated,time:.shortened)} ?? "Not yet")
                    Button("Sync now") {watch.syncHealth()}.disabled(watch.busy || !watch.connected)
                    Text("Syncs on connection and every 15 minutes while open. Background connection is managed by iOS.").font(.caption).foregroundStyle(.secondary)
                }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.cmfPaper).navigationTitle("Watch")
        }
    }
}
struct ConnectionSetupScreen:View {
    @EnvironmentObject var watch:WatchController
    @State private var scanning=false
    var body:some View {List {
        Section {LabeledContent("Device",value:"CMF Watch Pro 2");LabeledContent("Firmware",value:watch.firmwareVersion ?? "Connect to read");LabeledContent("Custom loader",value:watch.loaderVerified ? "Verified on this watch":"Not verified");Text(watch.status).font(.caption).foregroundStyle(.secondary)}
        Section {Button("Scan setup QR") {scanning=true};Button("Pair reset watch") {watch.pairResetWatch()};Text("Use reset pairing only when the watch is showing its initial setup screen.").font(.caption).foregroundStyle(.secondary)}
    }.navigationTitle("Connection").disabled(watch.busy).sheet(isPresented:$scanning) {NavigationStack {WatchQRScanner {result in scanning=false;switch result {case .success(let s):watch.acceptQR(s);case .failure(let e):watch.message=e.localizedDescription}}.navigationTitle("Scan watch QR").toolbar {Button("Cancel") {scanning=false}}}}}
}
struct WatchPreferencesScreen:View {
    @EnvironmentObject var watch:WatchController
    @State private var twelve=true
    @State private var imperial=true
    @State private var fahrenheit=true
    @State private var wrist=true
    var body:some View {List {
        Section("Time") {Toggle("12-hour clock",isOn:$twelve);Button("Apply time format") {watch.applySetting(.twelveHour(twelve))}}
        Section("Units") {Toggle("Miles and feet",isOn:$imperial);Button("Apply distance units") {watch.applySetting(.distanceImperial(imperial))};Toggle("Fahrenheit",isOn:$fahrenheit);Button("Apply temperature units") {watch.applySetting(.temperatureFahrenheit(fahrenheit))}}
        Section("Display") {Toggle("Raise wrist to wake",isOn:$wrist);Button("Apply wrist wake") {watch.applySetting(.wristWake(wrist))};Text("Brightness, always-on display and Do Not Disturb remain available in the watch's own Settings.").font(.caption).foregroundStyle(.secondary)}
        Section {Text("These are draft choices until you tap Apply and the watch acknowledges them. They do not claim to show current watch settings.").font(.caption).foregroundStyle(.secondary)}
        FeatureFeedback()
    }.navigationTitle("Display & units").disabled(watch.busy || !watch.connected)}
}
struct MonitoringScreen:View {
    @EnvironmentObject var watch:WatchController
    @State private var hr=true
    @State private var oxygen=true
    @State private var stress=false
    var body:some View {List {
        Section("24/7 monitoring") {Toggle("Heart rate",isOn:$hr);Button("Apply heart rate monitoring") {watch.applySetting(.monitoring(kind:1,enabled:hr))};Toggle("Blood oxygen",isOn:$oxygen);Button("Apply oxygen monitoring") {watch.applySetting(.monitoring(kind:2,enabled:oxygen))};Toggle("Stress",isOn:$stress);Button("Apply stress monitoring") {watch.applySetting(.monitoring(kind:4,enabled:stress))}}
        Section {Text("Draft choices are sent only when you tap Apply. Alert thresholds and automatic workout detection still use the watch or Nothing X.").font(.caption).foregroundStyle(.secondary)}
        FeatureFeedback()
    }.navigationTitle("Health monitoring").disabled(watch.busy || !watch.connected)}
}
struct GoalsScreen:View {
    @EnvironmentObject var watch:WatchController
    @AppStorage("goal-steps") private var steps=8000
    @AppStorage("goal-meters") private var meters=5000
    @AppStorage("goal-kcal") private var kcal=400
    var body:some View {List {Section("Daily targets") {Stepper("\(steps.formatted()) steps",value:$steps,in:2000...30000,step:500);Stepper(String(format:"%.1f miles",Double(meters)/1609.344),value:$meters,in:1000...99000,step:500);Stepper("\(kcal) active kcal",value:$kcal,in:100...5000,step:50);Button("Send goals to watch") {watch.applySetting(.goals(steps:UInt32(steps),meters:UInt32(meters),kcal:UInt16(kcal)))}};Section {Text("Targets are saved as a draft on this iPhone. Sending them updates all three watch targets.").font(.caption).foregroundStyle(.secondary)};FeatureFeedback()}.navigationTitle("Daily goals").disabled(watch.busy || !watch.connected)}
}
struct WatchProfileScreen:View {
    @EnvironmentObject var watch:WatchController
    @State private var height=170
    @State private var weight=70
    @State private var age=25
    @State private var male=false
    var body:some View {List {Section("Watch activity profile") {Stepper("Height: \(height) cm",value:$height,in:80...250);Stepper("Weight: \(weight) kg",value:$weight,in:20...250);Stepper("Age: \(age)",value:$age,in:5...120);Picker("Sex setting",selection:$male) {Text("Female").tag(false);Text("Male").tag(true)};Button("Send profile to watch") {watch.applySetting(.profile(height:UInt8(height),weight:UInt8(weight),age:UInt8(age),male:male))}};Section {Text("Enter your own values before sending. This profile affects the watch's activity estimates.").font(.caption).foregroundStyle(.secondary)};FeatureFeedback()}.navigationTitle("Personal profile").disabled(watch.busy || !watch.connected)}
}
struct StockFeatureGuide:View {
    var body:some View {List {
        Section("Available here") {Text("Pairing, battery status, offline maps, search, saved places and custom app transfers are available. Standard watch controls and health sync use documented commands; each operation requires the watch's acknowledgement.")}
        Section("Continue using Nothing X") {FeatureRow(title:"Calls & app notifications",subtitle:"Keep the system Bluetooth and Nothing X setup",icon:"bell");FeatureRow(title:"Weather & world clocks",subtitle:"Weather updates and city configuration",icon:"cloud.sun");FeatureRow(title:"Health integrations",subtitle:"Apple Health export and full workout history",icon:"heart.text.clipboard");FeatureRow(title:"Other stock tools",subtitle:"Quick replies, camera remote, music and advanced health alerts",icon:"ellipsis.circle")}
        Section {Text("This app is not yet a complete Nothing X replacement. Existing tools on the watch stay in the stock watch software. iPhone notifications depend on the system's accessory permissions; this app cannot read other apps' notifications.").font(.caption).foregroundStyle(.secondary);Link("Nothing X in the App Store",destination:URL(string:"https://apps.apple.com/app/id1568033706")!)}
    }.navigationTitle("Everyday features")}
}
