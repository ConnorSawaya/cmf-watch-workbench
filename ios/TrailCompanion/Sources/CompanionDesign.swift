import SwiftUI

extension Color {
    static let cmfInk=Color(red:0.10,green:0.11,blue:0.12)
    static let cmfPaper=Color(red:0.95,green:0.95,blue:0.96)
    static let cmfOrange=Color(red:0.91,green:0.24,blue:0.07)
    static let cmfGreen=Color(red:0.16,green:0.39,blue:0.30)
}
struct CompanionCard<Content:View>:View {
    let content:Content
    init(@ViewBuilder content:()->Content) {self.content=content()}
    var body:some View {VStack(alignment:.leading,spacing:0) {content}.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.background,in:RoundedRectangle(cornerRadius:18))}
}
struct Eyebrow:View {
    let text:String
    var body:some View {Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)}
}
struct ConnectionPill:View {
    @EnvironmentObject var watch:WatchController
    var body:some View {HStack(spacing:6) {Circle().fill(watch.connected || watch.stockPaired ? Color.cmfGreen:.gray).frame(width:6,height:6);Text(watch.connected || watch.stockPaired ? "Connected":"Disconnected").font(.caption.weight(.medium))}.fixedSize()}
}
struct WatchDrawing:View {
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:24).fill(Color(white:0.19)).frame(width:64,height:214)
            RoundedRectangle(cornerRadius:3).fill(Color(white:0.46)).frame(width:8,height:22).offset(x:78)
            Circle().fill(LinearGradient(colors:[Color(white:0.75),Color(white:0.34),Color(white:0.58)],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:160,height:160)
            Circle().fill(Color(white:0.04)).frame(width:147,height:147)
            Circle().stroke(Color.white.opacity(0.12),lineWidth:1).frame(width:139,height:139)
            TimelineView(.periodic(from:.now,by:60)) {context in
                VStack(spacing:5) {
                    Text(context.date.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()).font(.system(size:9,weight:.medium,design:.monospaced)).foregroundStyle(.white.opacity(0.6))
                    Text(context.date.formatted(.dateTime.hour(.defaultDigits(amPM:.omitted)).minute())).font(.system(size:29,weight:.light)).foregroundStyle(.white).monospacedDigit()
                    Capsule().fill(Color.cmfOrange).frame(width:20,height:3).padding(.top,6)
                }
            }
        }.frame(width:176,height:220).accessibilityLabel("Watch Pro 2 illustration").accessibilityHidden(true)
    }
}
struct FeatureRow:View {
    let title:String
    let subtitle:String
    let icon:String
    var color:Color = .cmfInk
    var body:some View {
        HStack(spacing:14) {
            Image(systemName:icon).font(.system(size:19,weight:.regular)).foregroundStyle(color).frame(width:26)
            VStack(alignment:.leading,spacing:3) {
                Text(title).font(.body).foregroundStyle(.primary)
                if !subtitle.isEmpty {Text(subtitle).font(.caption).foregroundStyle(.secondary)}
            }
        }.padding(.vertical,5)
    }
}
struct FeatureFeedback:View {
    @EnvironmentObject var watch:WatchController
    var body:some View {Section {if watch.busy {HStack(spacing:10) {ProgressView();Text(watch.status).font(.caption)}}else{Text(watch.featureStatus).font(.caption).foregroundStyle(.secondary)}}}
}
struct SyncStatus:View {
    @EnvironmentObject var watch:WatchController
    var body:some View {
        HStack(spacing:6) {
            if watch.busy {ProgressView().controlSize(.mini)}
            Text(watch.busy ? watch.status : watch.health.syncedAt.map{"Synced \($0.formatted(.relative(presentation:.named)))"} ?? "Waiting for first sync")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
