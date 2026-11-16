import SwiftUI
import CompanionCore

struct WatchScreen:View {
    @EnvironmentObject var watch:WatchController
    @EnvironmentObject var model:MapModel
    private var activity:[ActivityPoint] {watch.health.activity.filter{Calendar.current.isDateInToday(Date(timeIntervalSince1970:Double($0.timestamp)))}}
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    CompanionCard {
                        HStack(spacing:0) {
                            VStack(alignment:.leading,spacing:12) {
                                Text("CMF").font(.system(size:12,weight:.semibold,design:.monospaced)).tracking(3).foregroundStyle(.secondary)
                                Text("Watch Pro 2").font(.title2.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                                ConnectionPill()
                                if let battery=watch.battery {Label("\(battery)%",systemImage:watch.batteryCharging ? "battery.100percent.bolt":"battery.75percent").font(.subheadline.monospacedDigit()).padding(.top,4)}
                                Button(watch.connected || watch.stockPaired ? "Watch settings":"Connect watch") {if watch.connected || watch.stockPaired {model.activeTab=3}else{watch.connect()}}.font(.subheadline.weight(.medium)).disabled(watch.busy).padding(.top,4)
                            }.frame(maxWidth:.infinity,alignment:.leading)
                            WatchDrawing().scaleEffect(0.86).frame(width:145,height:198)
                        }
                        Divider().padding(.vertical,12)
                        SyncStatus()
                        if let p=watch.progress {ProgressView(value:p).tint(.cmfOrange).padding(.top,8)}
                    }
                    VStack(alignment:.leading,spacing:12) {
                        HStack {Text("Activity").font(.headline);Spacer();Button("View health") {model.activeTab=5}.font(.subheadline)}
                        CompanionCard {
                            HStack(alignment:.top,spacing:0) {
                                stat(activity.isEmpty ? "—":activity.reduce(UInt64(0)){$0+UInt64($1.steps)}.formatted(),"Steps")
                                stat(activity.isEmpty ? "—":String(format:"%.1f",Double(activity.reduce(UInt64(0)){$0+UInt64($1.meters)})/1609.344),"Miles")
                                stat(activity.isEmpty ? "—":String(format:"%.0f",Double(activity.reduce(UInt64(0)){$0+UInt64($1.calories)})/1000),"Active kcal")
                            }
                        }
                    }
                    Button {model.activeTab=0} label:{
                        HStack(spacing:18) {
                            Image(systemName:"map").font(.system(size:30,weight:.light)).foregroundStyle(Color.cmfOrange).frame(width:42)
                            VStack(alignment:.leading,spacing:5) {Text("Offline maps").font(.headline);Text("Your offline regions, places & routes").font(.caption).foregroundStyle(.secondary)}
                            Spacer();Image(systemName:"arrow.up.right").font(.subheadline).foregroundStyle(.secondary)
                        }.foregroundStyle(Color.cmfInk).padding(20).background(.white,in:RoundedRectangle(cornerRadius:18))
                    }.buttonStyle(.plain)
                    VStack(spacing:0) {
                        NavigationLink {WatchToolsScreen()} label:{HStack {FeatureRow(title:"Watch apps",subtitle:watch.trailMapInstalled ? "Trail Map installed":"Add Trail Map to your watch",icon:"square.grid.2x2");Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)}}.buttonStyle(.plain)
                        Divider().padding(.leading,40).padding(.vertical,9)
                        NavigationLink {AlarmsScreen()} label:{HStack {FeatureRow(title:"Alarms",subtitle:watch.alarms.map{"\($0.filter(\.enabled).count) active"} ?? "Manage on your watch",icon:"alarm");Spacer();Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)}}.buttonStyle(.plain)
                    }.padding(20).background(.white,in:RoundedRectangle(cornerRadius:18))
                }.padding(20).frame(maxWidth:650)
            }.refreshable {await watch.syncNow()}.frame(maxWidth:.infinity).background(Color.cmfPaper).navigationTitle("Today")
            .toolbar {ToolbarItem(placement:.topBarTrailing) {Button {watch.syncHealth()} label:{Image(systemName:"arrow.triangle.2.circlepath")}.accessibilityLabel("Sync watch").disabled(watch.busy || !watch.connected)}}
        }
    }
    private func stat(_ value:String,_ label:String)->some View {VStack(alignment:.leading,spacing:7) {Text(value).font(.system(size:25,weight:.medium)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1);Text(label).font(.caption).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading)}
}
