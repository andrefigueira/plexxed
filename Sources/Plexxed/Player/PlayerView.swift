import AppKit
import SwiftUI

/// UI state for the player that isn't playback state: control visibility, window, keyboard.
@MainActor
@Observable
final class PlayerChrome {
    struct HUD: Equatable {
        let symbol: String
        let level: Double
        let id = UUID()
    }

    var controlsVisible = true
    var hoveringControls = false
    var tracksOpen = false
    var fullscreen = false
    var hud: HUD?

    @ObservationIgnored weak var session: PlaybackSession?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var hudTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var enteredFullscreen = false

    private static let idleDelay: TimeInterval = 2.5

    func start(session: PlaybackSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let key = KeyPress(
                code: event.keyCode,
                character: event.charactersIgnoringModifiers?.lowercased(),
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            )
            let handled = MainActor.assumeIsolated { self?.handleKey(key) ?? false }
            return handled ? nil : event
        }
        poke()
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        hideTask?.cancel()
        hudTask?.cancel()
        setWindowButtons(visible: true)
        if enteredFullscreen, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func attach(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        self.window = window
        fullscreen = window.styleMask.contains(.fullScreen)
    }

    // MARK: Idle hiding

    private var canHide: Bool {
        guard let session else { return false }
        return !session.paused && !hoveringControls && !tracksOpen && session.errorMessage == nil
    }

    /// Any sign of the user: show the controls and restart the idle clock.
    func poke() {
        lastActivity = Date()
        if !controlsVisible {
            controlsVisible = true
            setWindowButtons(visible: true)
        }
        guard hideTask == nil else { return }
        hideTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = lastActivity.addingTimeInterval(Self.idleDelay).timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
                if canHide {
                    controlsVisible = false
                    setWindowButtons(visible: false)
                    NSCursor.setHiddenUntilMouseMoves(true)
                }
                hideTask = nil
                return
            }
        }
    }

    private func setWindowButtons(visible: Bool) {
        guard let titlebar = window?.standardWindowButton(.closeButton)?.superview else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            titlebar.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Actions

    func toggleFullscreen() {
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) { enteredFullscreen = true }
        window.toggleFullScreen(nil)
    }

    func showHUD(symbol: String, level: Double) {
        hud = HUD(symbol: symbol, level: level)
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }

    func changeVolume(by delta: Double) {
        guard let session else { return }
        let level = min(max(session.volume + delta, 0), 100)
        session.setVolume(level)
        showHUD(symbol: Self.volumeSymbol(level: level, muted: false), level: level / 100)
    }

    func toggleMute() {
        guard let session else { return }
        session.toggleMute()
        let muted = !session.muted
        showHUD(symbol: Self.volumeSymbol(level: session.volume, muted: muted), level: muted ? 0 : session.volume / 100)
    }

    static func volumeSymbol(level: Double, muted: Bool) -> String {
        if muted || level <= 0 { return "speaker.slash.fill" }
        if level < 34 { return "speaker.wave.1.fill" }
        if level < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    struct KeyPress: Sendable {
        let code: UInt16
        let character: String?
        let modifiers: NSEvent.ModifierFlags
    }

    /// Returns true when the key was handled.
    private func handleKey(_ key: KeyPress) -> Bool {
        guard let session else { return false }
        let modifiers = key.modifiers
        if modifiers.contains(.command) {
            // ⌘W closes the player rather than the window.
            if key.character == "w" {
                onClose?()
                return true
            }
            return false
        }
        let step: Double = modifiers.contains(.shift) ? 60 : 10
        switch key.code {
        case 49: session.togglePause()
        case 123: session.seek(by: -step)
        case 124: session.seek(by: step)
        case 126: changeVolume(by: 5)
        case 125: changeVolume(by: -5)
        case 53:
            if tracksOpen {
                tracksOpen = false
            } else if window?.styleMask.contains(.fullScreen) == true {
                window?.toggleFullScreen(nil)
            } else {
                onClose?()
            }
            return true
        default:
            switch key.character {
            case "f": toggleFullscreen()
            case "m": toggleMute()
            case "s": session.skipIntro()
            case "n": session.playNext()
            default: return false
            }
        }
        poke()
        return true
    }
}

struct PlayerView: View {
    let session: PlaybackSession
    @Environment(AppModel.self) private var app
    @State private var chrome = PlayerChrome()

    var body: some View {
        ZStack {
            Color.black
            if let view = session.videoView {
                VideoSurface(view: view)
            }
            clickCatcher
            DelayedSpinner(active: session.buffering && !session.paused && session.errorMessage == nil)
            if let error = session.errorMessage {
                ErrorPanel(message: error) { app.closePlayer() }
            }
            overlay
            if let hud = chrome.hud {
                VolumeHUD(hud: hud).transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .background(WindowReader { chrome.attach($0) })
        .onContinuousHover { phase in
            if case .active = phase { chrome.poke() }
        }
        .onAppear { chrome.start(session: session) { app.closePlayer() } }
        .onDisappear { chrome.stop() }
        .onChange(of: session.paused) { chrome.poke() }
        .onChange(of: chrome.tracksOpen) { chrome.poke() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            chrome.fullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            chrome.fullscreen = false
        }
        .animation(.calm, value: chrome.controlsVisible)
        .animation(.calm, value: session.showsUpNext)
        .animation(.calm, value: session.activeIntro)
        .animation(.quick, value: chrome.hud)
    }

    private var clickCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2).onEnded { chrome.toggleFullscreen() }
                    .exclusively(before: TapGesture(count: 1).onEnded {
                        session.togglePause()
                        chrome.poke()
                    })
            )
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            if chrome.controlsVisible {
                topBar.transition(.opacity)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                floatingActions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
            if chrome.controlsVisible {
                ControlBar(session: session, chrome: chrome)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { app.closePlayer() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back to library (Esc)")
            .accessibilityLabel("Back to library")

            Text(session.title)
                .font(.body13Strong)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let subtitle = session.subtitle {
                Text(subtitle)
                    .font(.body13)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, chrome.fullscreen ? 28 : 84)
        .padding(.trailing, 28)
        .padding(.top, chrome.fullscreen ? 22 : 0)
        .frame(height: chrome.fullscreen ? 72 : 30, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            // A scrim keeps the title legible on bright footage.
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .opacity(0.55)
                .frame(height: 150)
                .allowsHitTesting(false)
        }
        .gesture(WindowDragGesture())
        .onHover { chrome.hoveringControls = $0 }
    }

    @ViewBuilder
    private var floatingActions: some View {
        if session.showsUpNext, let next = session.nextEpisode, let countdown = session.upNextCountdown {
            UpNextCard(session: session, next: next, countdown: countdown)
                .transition(.opacity)
                .onHover { chrome.hoveringControls = $0 }
        } else if session.activeIntro != nil {
            Button("Skip Intro") { session.skipIntro() }
                .buttonStyle(.glass)
                .controlSize(.extraLarge)
                .help("Skip Intro (S)")
                .transition(.opacity)
        }
    }
}

// MARK: - Control bar

private struct ControlBar: View {
    let session: PlaybackSession
    @Bindable var chrome: PlayerChrome

    var body: some View {
        HStack(spacing: 14) {
            ControlButton(systemImage: "gobackward.10", help: "Back 10 seconds (←)") { session.seek(by: -10) }
            ControlButton(systemImage: session.paused ? "play.fill" : "pause.fill", size: 20, help: session.paused ? "Play (Space)" : "Pause (Space)") {
                session.togglePause()
            }
            ControlButton(systemImage: "goforward.10", help: "Forward 10 seconds (→)") { session.seek(by: 10) }

            Text(Format.clock(session.position))
                .frame(minWidth: 52, alignment: .trailing)
            Scrubber(position: session.position, duration: session.duration) { session.seek(to: $0) }
            Text("-" + Format.clock(max(session.duration - session.position, 0)))
                .frame(minWidth: 58, alignment: .leading)

            ControlButton(systemImage: "captions.bubble", help: "Audio and subtitles") { chrome.tracksOpen.toggle() }
                .popover(isPresented: $chrome.tracksOpen, arrowEdge: .top) {
                    TrackPanel(session: session)
                }
            VolumeControl(session: session, chrome: chrome)
            ControlButton(
                systemImage: chrome.fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: chrome.fullscreen ? "Exit full screen (F)" : "Full screen (F)"
            ) { chrome.toggleFullscreen() }
        }
        .font(.body13.monospacedDigit())
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 18)
        .frame(height: 56)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 1040)
        .onHover { chrome.hoveringControls = $0 }
    }
}

private struct ControlButton: View {
    let systemImage: String
    var size: CGFloat = 15
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 32, height: 32)
                .scaleEffect(hovered ? 1.08 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.quick, value: hovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A thin timeline that thickens on hover and shows the time under the pointer.
/// Seeks once on release, so dragging doesn't flood the server with range requests.
private struct Scrubber: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var hoverX: CGFloat?
    @State private var dragTime: Double?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = dragTime ?? position
            let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
            let active = hoverX != nil || dragTime != nil
            let barHeight: CGFloat = active ? 6 : 4

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: barHeight)
                Capsule().fill(Theme.accent).frame(width: width * fraction, height: barHeight)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 13, height: 13)
                    .offset(x: width * fraction - 6.5)
                    .opacity(active ? 1 : 0)
                if let x = dragTime.map({ CGFloat($0 / max(duration, 1)) * width }) ?? hoverX, duration > 0 {
                    Text(Format.clock(Double(x / width) * duration))
                        .font(.caption11.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                        .offset(x: min(max(x - 26, 0), width - 52), y: -26)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = min(max(point.x, 0), width)
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragTime = Double(min(max(value.location.x / width, 0), 1)) * duration
                    }
                    .onEnded { value in
                        let target = Double(min(max(value.location.x / width, 0), 1)) * duration
                        dragTime = nil
                        onSeek(target)
                    }
            )
            .animation(.quick, value: active)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Format.clock(position))
        .accessibilityAdjustableAction { direction in
            onSeek(min(max(position + (direction == .increment ? 10 : -10), 0), duration))
        }
    }
}

private struct VolumeControl: View {
    let session: PlaybackSession
    let chrome: PlayerChrome
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            ControlButton(
                systemImage: PlayerChrome.volumeSymbol(level: session.volume, muted: session.muted),
                help: session.muted ? "Unmute (M)" : "Mute (M)"
            ) { session.toggleMute() }
            if hovered {
                MiniSlider(value: session.muted ? 0 : session.volume / 100) { session.setVolume($0 * 100) }
                    .frame(width: 84)
                    .transition(.opacity)
            }
        }
        .onHover { inside in withAnimation(.quick) { hovered = inside } }
    }
}

private struct MiniSlider: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: width * value, height: 4)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(Double(min(max(drag.location.x / width, 0), 1)))
            })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

// MARK: - Panels

private struct TrackPanel: View {
    let session: PlaybackSession

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            column("Audio", session.audioOptions, empty: "No audio tracks")
            column("Subtitles", session.subtitleOptions, empty: "No subtitles")
        }
        .padding(14)
        .frame(width: 540)
    }

    private func column(_ title: String, _ options: [TrackOption], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.body13Strong)
                .foregroundStyle(Theme.textPrimary)
                .padding(.leading, 10)
            if options.isEmpty {
                Text(empty).font(.body13).foregroundStyle(Theme.textSecondary).padding(.leading, 10)
            } else if options.count > 10 {
                ScrollView { rows(options) }.frame(height: 340)
            } else {
                rows(options)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rows(_ options: [TrackOption]) -> some View {
        VStack(spacing: 2) {
            ForEach(options) { option in
                MenuRow(title: option.title, detail: option.detail, selected: option.selected) {
                    session.select(option)
                }
            }
        }
    }
}

private struct UpNextCard: View {
    let session: PlaybackSession
    let next: PlexItem
    let countdown: Int

    var body: some View {
        HStack(spacing: 14) {
            PlexImage(session.server.image(next.thumb, width: ArtSize.still.width, height: ArtSize.still.height))
                .frame(width: 144, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text("Next episode in \(countdown)")
                    .font(.caption11.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Text([next.episodeLabel, next.title].compactMap { $0 }.joined(separator: "  "))
                    .font(.body13Strong)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 16) {
                    PrimaryButton("Play now", systemImage: "play.fill") { session.playNext() }
                    TextButton("Hide") { session.dismissUpNext() }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 400)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct ErrorPanel: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Can't play this").font(.heading).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.body13)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 380, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton("Back to library", systemImage: "chevron.left", action: onClose)
                .padding(.top, 4)
        }
        .padding(28)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct VolumeHUD: View {
    let hud: PlayerChrome.HUD

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: hud.symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
            ProgressLine(fraction: hud.level).frame(width: 120)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 18)
        .frame(height: 48)
        .glassEffect(.regular, in: Capsule())
        .allowsHitTesting(false)
    }
}

/// Shows a spinner only when buffering lasts long enough to notice, so quick seeks don't flash one.
private struct DelayedSpinner: View {
    let active: Bool
    @State private var shown = false

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .task(id: active) {
                guard active else {
                    shown = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { withAnimation(.quick) { shown = true } }
            }
    }
}

// MARK: - AppKit bridges

private struct VideoSurface: NSViewRepresentable {
    let view: MPVVideoView
    func makeNSView(context: Context) -> MPVVideoView { view }
    func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}

struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onWindow(nsView?.window) }
    }
}
