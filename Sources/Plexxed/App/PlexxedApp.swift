import AppKit
import SwiftUI

@main
struct PlexxedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Plexxed", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 600)
                .preferredColorScheme(.dark)
                .containerBackground(Theme.background, for: .window)
                .task {
                    delegate.model = app
                    await app.bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Playback") {
                // Space, arrows and the other player keys are handled by the player itself.
                Button(app.playback?.paused == true ? "Play" : "Pause") { app.playback?.togglePause() }
                    .disabled(app.playback == nil)
                Button("Skip Intro") { app.playback?.skipIntro() }
                    .disabled(app.playback?.activeIntro == nil)
                Button("Next Episode") { app.playback?.playNext() }
                    .disabled(app.playback?.nextEpisode == nil)
                Divider()
                Button("Leave Player") { app.closePlayer() }
                    .disabled(app.playback == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(app)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Holds the quit for the final playback report. Two seconds at most, in case the server is gone.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.playback != nil else { return .terminateNow }
        if quitting { return .terminateLater }
        quitting = true
        Task {
            await model.closePlayerBeforeQuit()
            finishQuit(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            finishQuit(sender)
        }
        return .terminateLater
    }

    private func finishQuit(_ sender: NSApplication) {
        guard quitting else { return }
        quitting = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}
