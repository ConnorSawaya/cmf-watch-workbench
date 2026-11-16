import SwiftUI
import CompanionCore

struct AlarmsScreen:View {
    @EnvironmentObject var watch:WatchController
    @State private var editing:WatchAlarm?
    var body:some View {List {
        Section {Button("Read alarms from watch") {watch.loadAlarms()}.disabled(watch.busy || !watch.connected)}
        if let alarms=watch.alarms {
            Section {
                ForEach(alarms.sorted{$0.seconds<$1.seconds}) {alarm in
                    Button {editing=alarm} label:{HStack {VStack(alignment:.leading,spacing:6) {Text(time(alarm.seconds)).font(.system(size:34,weight:.light,design:.rounded)).monospacedDigit();Text([alarm.label,alarm.weekdays==127 ? "Every day":alarm.weekdays==0 ? "Once":"Custom repeat"].joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:alarm.enabled ? "checkmark.circle.fill":"circle").foregroundStyle(alarm.enabled ? Color.cmfOrange:.gray)}}.foregroundStyle(.primary)
                }
                if alarms.count<5 {Button {let taken=Set(alarms.map(\.id));if let id=(UInt8(0)...4).first(where:{!taken.contains($0)}) {editing=WatchAlarm(id:id)}} label:{Label("Add alarm",systemImage:"plus")}}
            }
        }else {Section {ContentUnavailableView("Your watch's alarms",systemImage:"alarm",description:Text("Read the existing alarms first, so editing one preserves the others."))}}
        FeatureFeedback()
    }.navigationTitle("Alarms").sheet(item:$editing) {alarm in AlarmEditor(alarm:alarm) {value in var all=watch.alarms ?? [];if let i=all.firstIndex(where:{$0.id==value.id}) {all[i]=value}else{all.append(value)};watch.saveAlarms(all)}}}
    private func time(_ s:UInt32)->String {let c=DateComponents(hour:Int(s/3600),minute:Int(s%3600/60));return Calendar.current.date(from:c)?.formatted(date:.omitted,time:.shortened) ?? "—"}
}
struct AlarmEditor:View {
    @Environment(\.dismiss) var dismiss
    @State var alarm:WatchAlarm
    let save:(WatchAlarm)->Void
    var body:some View {NavigationStack {Form {
        DatePicker("Time",selection:Binding(get:{Calendar.current.date(from:DateComponents(hour:Int(alarm.seconds/3600),minute:Int(alarm.seconds%3600/60))) ?? .now},set:{alarm.seconds=UInt32(Calendar.current.component(.hour,from:$0)*3600+Calendar.current.component(.minute,from:$0)*60)}),displayedComponents:.hourAndMinute)
        TextField("Label",text:$alarm.label)
        Toggle("Enabled",isOn:$alarm.enabled)
        Picker("Repeat",selection:$alarm.weekdays) {Text("Once").tag(UInt8(0));Text("Every day").tag(UInt8(127));if alarm.weekdays != 0 && alarm.weekdays != 127 {Text("Keep custom days").tag(alarm.weekdays)}}
        Text("Labels can use up to 32 UTF-8 bytes. Disable an alarm here when you no longer need it.").font(.caption).foregroundStyle(.secondary)
    }.navigationTitle("Edit alarm").toolbar {ToolbarItem(placement:.cancellationAction) {Button("Cancel") {dismiss()}};ToolbarItem(placement:.confirmationAction) {Button("Save") {save(alarm);dismiss()}.disabled(alarm.label.utf8.count>32)}}}}
}
struct ReminderScreen:View {
    @EnvironmentObject var watch:WatchController
    let ability:UInt16
    let title:String
    @State private var value=WatchReminder()
    var body:some View {List {
        Section {Button("Read from watch") {watch.loadReminder(ability)}}
        Section("Reminder") {Toggle("Enabled",isOn:$value.enabled);Stepper("Every \(value.minutes) minutes",value:$value.minutes,in:15...240,step:15);DatePicker("Quiet hours start",selection:clock(\.quietStart),displayedComponents:.hourAndMinute);DatePicker("Quiet hours end",selection:clock(\.quietEnd),displayedComponents:.hourAndMinute);Button("Save to watch") {watch.saveReminder(ability,value)}.disabled(watch.reminders[ability]==nil)}
        Section {Text("Read the current setting before editing. The watch controls its default daytime reminder window.").font(.caption).foregroundStyle(.secondary)}
        FeatureFeedback()
    }.navigationTitle(title).disabled(watch.busy || !watch.connected).onAppear {if let r=watch.reminders[ability] {value=r}}.onChange(of:watch.reminders[ability]) {_,v in if let v {value=v}}}
    private func clock(_ key:WritableKeyPath<WatchReminder,UInt32>)->Binding<Date> {Binding(get:{let s=value[keyPath:key];return Calendar.current.date(from:DateComponents(hour:Int(s/3600),minute:Int(s%3600/60))) ?? .now},set:{value[keyPath:key]=UInt32(Calendar.current.component(.hour,from:$0)*3600+Calendar.current.component(.minute,from:$0)*60)})}
}
struct ContactsScreen:View {
    @EnvironmentObject var watch:WatchController
    @State private var draft=[WatchContact]()
    @State private var name=""
    @State private var number=""
    var body:some View {List {
        Section {Button("Read contacts from watch") {watch.loadContacts()}}
        if watch.contacts != nil {
            Section("On-watch list · \(draft.count) / 20") {ForEach(draft) {c in VStack(alignment:.leading,spacing:4) {Text(c.name);Text(c.number).font(.caption).foregroundStyle(.secondary)}}.onDelete {draft.remove(atOffsets:$0)}}
            if draft.count<20 {Section("Add contact") {TextField("Name",text:$name);TextField("Phone number",text:$number).keyboardType(.phonePad);Button("Add to draft") {draft.append(WatchContact(name:name,number:number));name="";number=""}.disabled(name.isEmpty || number.isEmpty || name.utf8.count>32 || number.utf8.count>25)}}
            Section {Button("Replace watch contacts with this list") {watch.saveContacts(draft)};Text("Nothing is sent until you tap Replace. Names support 32 UTF-8 bytes and numbers 25 bytes.").font(.caption).foregroundStyle(.secondary)}
        }else{Section {ContentUnavailableView("Frequent contacts",systemImage:"person.crop.circle",description:Text("Read the watch's current list before replacing it."))}}
        FeatureFeedback()
    }.navigationTitle("Contacts").disabled(watch.busy || !watch.connected).onAppear {draft=watch.contacts ?? []}.onChange(of:watch.contacts) {_,v in if let v {draft=v}}}
}
