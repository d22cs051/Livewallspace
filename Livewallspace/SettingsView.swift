import SwiftUI
import Combine

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Form {
                Section("General") {
                    Toggle("Start Livewallspace on Login", isOn: Binding(
                        get: { viewModel.startOnLoginEnabled },
                        set: { viewModel.setStartOnLogin($0) }
                    ))

                    Toggle("Use Native Lock Screen Integration (macOS 15+)", isOn: Binding(
                        get: { viewModel.nativeLockScreenIntegrationEnabled },
                        set: { viewModel.setNativeLockScreenIntegration($0) }
                    ))
                    .disabled(
                        !viewModel.nativeLockScreenSupported ||
                        !viewModel.nativeLockScreenConfigured ||
                        !viewModel.nativeLockScreenExtensionInstalled
                    )

                    Text(nativeIntegrationDescription)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Open Wallpaper Settings") {
                            viewModel.openWallpaperSettingsForIntegration()
                        }
                    }

                    HStack {
                        Button(viewModel.systemCatalogSyncInProgress ? "Syncing..." : "Sync Current Video to System Catalog") {
                            viewModel.syncCurrentVideoToSystemCatalog()
                        }
                        .disabled(viewModel.systemCatalogSyncInProgress)

                        Text("Use this if the Livewallspace block does not appear automatically.")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Enable Lock Screen Continuity", isOn: Binding(
                        get: { viewModel.lockScreenContinuityEnabled },
                        set: { viewModel.setLockScreenContinuity($0) }
                    ))

                    Text("macOS lock screen is protected by system security. When enabled, Livewallspace updates the system desktop picture using a still frame from your current video to preserve visual continuity.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Section("Cache") {
                    HStack {
                        Text("Downloaded videos")
                        Spacer()
                        Text(viewModel.cacheSizeLabel())
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Refresh Size") {
                            viewModel.refreshCacheSize()
                        }

                        Button("Clear Cache") {
                            viewModel.clearCache()
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                    NSApp.keyWindow?.performClose(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white, in: Capsule(style: .continuous))
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 360)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private extension SettingsView {
    var nativeIntegrationDescription: String {
        if !viewModel.nativeLockScreenSupported {
            return "Native lock-screen video integration requires macOS 15 or later."
        }

        if !viewModel.nativeLockScreenConfigured {
            return "App Group entitlement is not active yet. Enable group.com.livewallspace.shared for both app and extension targets."
        }

        if !viewModel.nativeLockScreenExtensionInstalled {
            return "Native lock-screen integration is currently unavailable for this build."
        }

        return "Uses Apple's system lock screen pipeline once the Livewallspace extension is selected in Wallpaper settings."
    }
}
