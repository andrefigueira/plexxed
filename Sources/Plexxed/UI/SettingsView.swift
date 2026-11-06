import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var cacheSize: Int64?

    var body: some View {
        Form {
            Section("Server") {
                if let server = app.server {
                    LabeledContent("Name", value: server.name)
                    LabeledContent("Address", value: server.baseURL.absoluteString)
                        .textSelection(.enabled)
                    Button("Choose another server") {
                        Task { await app.discoverServers(alwaysAsk: true) }
                    }
                } else {
                    Text("Not connected").foregroundStyle(Theme.textSecondary)
                }
            }
            Section("Storage") {
                LabeledContent("Artwork cache", value: cacheSize.map(Format.bytes) ?? "Measuring")
                Button("Clear artwork cache") {
                    ImagePipeline.shared.clearAll()
                    cacheSize = 0
                }
            }
            Section("Account") {
                Button("Sign out", role: .destructive) { app.signOut() }
                    .disabled(app.phase == .signedOut)
            }
            Section("Keyboard") {
                LabeledContent("Play or pause", value: "Space")
                LabeledContent("Back or forward 10 s", value: "← →  (Shift for 60 s)")
                LabeledContent("Volume", value: "↑ ↓")
                LabeledContent("Mute", value: "M")
                LabeledContent("Full screen", value: "F or double-click")
                LabeledContent("Skip intro", value: "S")
                LabeledContent("Next episode", value: "N")
                LabeledContent("Leave the player", value: "Esc or ⌘W")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            cacheSize = await Task.detached(priority: .utility) { ImagePipeline.shared.diskUsage() }.value
        }
    }
}
