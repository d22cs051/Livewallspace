import AppKit
import SwiftUI
import SwiftData
import Combine

@main
struct LivewallspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var wallpaperManager = WallpaperManager.shared

    var body: some Scene {
        WindowGroup("Livewallspace") {
            MainShellView()
                .background(WindowChromeConfigurator())
                .onAppear {
                    wallpaperManager.start()
                }
        }
        .modelContainer(for: [VideoItem.self, Playlist.self])
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}
