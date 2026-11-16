import SwiftUI

@main
struct WorkbenchApp: App {
  @StateObject private var watch = WatchController()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      WorkbenchScreen().environmentObject(watch).preferredColorScheme(.light)
        .onChange(of: phase) { _, value in watch.setForeground(value == .active) }
    }
  }
}

struct WorkbenchScreen: View {
  @EnvironmentObject var watch: WatchController
  @State private var tab = 0
  var body: some View {
    TabView(selection: $tab) {
      NavigationStack { WatchToolsScreen() }.tabItem {
        Label("Apps", systemImage: "square.grid.2x2")
      }.tag(0)
      NavigationStack { WatchFacesScreen() }.tabItem {
        Label("Faces", systemImage: "applewatch.watchface")
      }.tag(1)
      SettingsScreen().tabItem { Label("Watch", systemImage: "applewatch") }.tag(3)
    }.tint(.cmfOrange)
      .alert(
        "Watch",
        isPresented: Binding(get: { watch.message != nil }, set: { if !$0 { watch.message = nil } })
      ) {
        Button("OK") { watch.message = nil }
      } message: {
        Text(watch.message ?? "")
      }
      .onAppear {
        if let i = CommandLine.arguments.firstIndex(of: "-start-tab"),
          i + 1 < CommandLine.arguments.count, let value = Int(CommandLine.arguments[i + 1]),
          [0, 1, 3].contains(value)
        {
          tab = value
        }
      }
  }
}
