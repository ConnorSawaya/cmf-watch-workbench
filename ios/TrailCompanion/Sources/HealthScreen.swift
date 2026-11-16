import SwiftUI
import CompanionCore

struct HealthScreen:View {
    @EnvironmentObject var watch:WatchController
    @State private var day=Date()
    private var activity:[ActivityPoint] {watch.health.activity.filter{sameDay($0.timestamp)}}
    private func sameDay(_ ts:UInt32)->Bool {Calendar.current.isDate(Date(timeIntervalSince1970:Double(ts)),inSameDayAs:day)}
    private func latest(_ metric:UInt16)->HealthPoint? {watch.health.points.filter{$0.metric==metric && sameDay($0.timestamp)}.max{$0.timestamp<$1.timestamp}}
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    HStack {SyncStatus();Spacer();DatePicker("Day",selection:$day,in:...Date(),displayedComponents:.date).labelsHidden()}
                    CompanionCard {
                        VStack(alignment:.leading,spacing:20) {
                            HStack {Label("Daily activity",systemImage:"figure.walk").font(.headline);Spacer()}
                            HStack(alignment:.firstTextBaseline,spacing:6) {Text(activity.isEmpty ? "—":activity.reduce(UInt64(0)){$0+UInt64($1.steps)}.formatted()).font(.system(size:46,weight:.medium)).monospacedDigit();Text("steps").foregroundStyle(.secondary)}
                            HStack(spacing:36) {mini(activity.isEmpty ? "—":String(format:"%.2f",Double(activity.reduce(UInt64(0)){$0+UInt64($1.meters)})/1609.344),"Miles");mini(activity.isEmpty ? "—":String(format:"%.0f",Double(activity.reduce(UInt64(0)){$0+UInt64($1.calories)})/1000),"Active kcal")}
                        }
                    }
                    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:12) {
                        metric("Heart rate",0x53,"heart.fill","bpm",.red)
                        metric("Resting heart rate",0xda,"heart","bpm",.pink)
                        metric("Blood oxygen",0x55,"drop.fill","%",.blue)
                        metric("Stress",0x9d,"waveform.path","",.cmfGreen)
                    }
                    CompanionCard {
                        let sessions=watch.health.sleep.filter{sameDay($0.end)}
                        let seconds=sessions.reduce(0){$0+Int($1.deep)+Int($1.light)+Int($1.rem)}
                        VStack(alignment:.leading,spacing:14) {
                            Label("Sleep",systemImage:"moon.fill").font(.headline).foregroundStyle(.indigo)
                            Text(sessions.isEmpty ? "—":"\(seconds/3600)h \((seconds%3600)/60)m").font(.system(size:34,weight:.medium))
                            if sessions.isEmpty {Text("No sleep records synced for this day.").font(.caption).foregroundStyle(.secondary)}
                            else {HStack {ForEach([("Deep",sessions.reduce(0){$0+Int($1.deep)}),("Light",sessions.reduce(0){$0+Int($1.light)}),("REM",sessions.reduce(0){$0+Int($1.rem)})],id:\.0) {v in mini("\(v.1/60)m",v.0)}}}
                        }
                    }
                    CompanionCard {
                        VStack(alignment:.leading,spacing:12) {
                            Label("Watch sync",systemImage:"arrow.triangle.2.circlepath").font(.headline)
                            Text(watch.health.syncedAt.map{"Last completed sync \($0.formatted(date:.abbreviated,time:.shortened))"} ?? "Measurements will appear after your watch syncs.").font(.subheadline).foregroundStyle(.secondary)
                            Button {watch.syncHealth()} label:{Label(watch.busy ? watch.status:"Sync from watch",systemImage:"arrow.clockwise").frame(maxWidth:.infinity).padding(.vertical,7)}.buttonStyle(.borderedProminent).tint(.cmfInk).disabled(watch.busy || !watch.connected)
                            Text(watch.autoSync ? "Automatic sync is on. Health data stays on this iPhone.":"Health data stays on this iPhone.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(20)
            }.refreshable {await watch.syncNow()}.background(Color.cmfPaper).navigationTitle("Health").navigationBarTitleDisplayMode(.large)
        }
    }
    private func mini(_ value:String,_ label:String)->some View {VStack(alignment:.leading,spacing:5) {Text(value).font(.title3.weight(.medium)).monospacedDigit();Eyebrow(text:label)}}
    private func metric(_ title:String,_ id:UInt16,_ icon:String,_ unit:String,_ color:Color)->some View {
        NavigationLink {HealthMetricDetail(title:title,metric:id,unit:unit,day:day)} label:{CompanionCard {VStack(alignment:.leading,spacing:14) {Image(systemName:icon).foregroundStyle(color).font(.title3);Text(title).font(.subheadline).foregroundStyle(.secondary);HStack(alignment:.firstTextBaseline,spacing:3) {Text(latest(id).map{String(format:"%.0f",$0.value)} ?? "—").font(.system(size:30,weight:.medium));Text(unit).font(.caption).foregroundStyle(.secondary)}}}.foregroundStyle(Color.cmfInk)}.buttonStyle(.plain)
    }
}
struct HealthMetricDetail:View {
    @EnvironmentObject var watch:WatchController
    let title:String
    let metric:UInt16
    let unit:String
    let day:Date
    private var samples:[HealthPoint] {watch.health.points.filter{$0.metric==metric && Calendar.current.isDate(Date(timeIntervalSince1970:Double($0.timestamp)),inSameDayAs:day)}.sorted{$0.timestamp<$1.timestamp}}
    var body:some View {List {Section {if samples.isEmpty {ContentUnavailableView("No synced measurements",systemImage:"waveform.path",description:Text("Wear the watch, record a measurement, then sync it on the Health tab."))}else{ForEach(Array(samples.suffix(100).reversed())) {p in LabeledContent(Date(timeIntervalSince1970:Double(p.timestamp)).formatted(date:.omitted,time:.shortened),value:String(format:"%.0f %@",p.value,unit))}}};Section {Text("Recorded by CMF Watch Pro 2. These are wellness measurements.").font(.caption).foregroundStyle(.secondary)}}.navigationTitle(title)}
}
