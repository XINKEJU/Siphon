import SwiftUI

/// Settings scene (⌘,). macOS convention: tabs/panes, no "Save" button — changes
/// apply immediately, destructive actions are clearly separated. Each tab lives
/// in its own file; this struct only assembles the TabView.
struct SettingsView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView().tabItem { Label("通用", systemImage: "gear") }.tag(0)
            SpeedSettingsView().tabItem { Label("速度", systemImage: "speedometer") }.tag(1)
            SettingsQueuesView().tabItem { Label("队列", systemImage: "list.bullet.rectangle") }.tag(2)
            IntegrationSettingsView().tabItem { Label("集成", systemImage: "link") }.tag(3)
            GatewaySettingsView().tabItem { Label("协议网关", systemImage: "network") }.tag(4)
            AboutSettingsView().tabItem { Label("关于", systemImage: "info.circle") }.tag(5)
        }
        .frame(width: 560, height: 440)
        .padding()
    }
}
