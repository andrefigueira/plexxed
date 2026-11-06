import SwiftUI

/// Drives the detail column's navigation stack so any view can open an item.
@MainActor
@Observable
final class Navigator {
    var path: [PlexItem] = []

    func open(_ item: PlexItem) {
        if path.last?.ratingKey != item.ratingKey { path.append(item) }
    }

    func reset() { path = [] }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Group {
                switch app.phase {
                case .ready:
                    MainView()
                case .launching:
                    Theme.background
                case .signedOut:
                    SignInView(waitingURL: nil)
                case .awaitingApproval(let url):
                    SignInView(waitingURL: url)
                case .choosingServer(let servers):
                    ServerPickerView(servers: servers)
                case .connecting(let message):
                    StatusView(message: message)
                case .failed(let message):
                    FailureView(message: message)
                }
            }
            .allowsHitTesting(app.playback == nil)

            if let session = app.playback {
                PlayerView(session: session)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.calm, value: app.playback == nil)
        .background(Theme.background)
        .toolbarVisibility(app.playback == nil ? .automatic : .hidden, for: .windowToolbar)
    }
}

// MARK: - Main

enum SidebarItem: Hashable {
    case home
    case section(String)

    init(stored: String?) {
        if let stored, stored.hasPrefix("section:") {
            self = .section(String(stored.dropFirst("section:".count)))
        } else {
            self = .home
        }
    }

    var stored: String {
        switch self {
        case .home: "home"
        case .section(let key): "section:\(key)"
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: SidebarItem? = SidebarItem(stored: UserDefaults.standard.string(forKey: "sidebar"))
    @State private var navigator = Navigator()
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
        } detail: {
            NavigationStack(path: $navigator.path) {
                content
                    .navigationDestination(for: PlexItem.self) { item in
                        DetailView(item: item)
                    }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Movies, shows, episodes")
        .environment(navigator)
        .onChange(of: selection) {
            navigator.reset()
            query = ""
            UserDefaults.standard.set(selection?.stored, forKey: "sidebar")
        }
        .onChange(of: query) {
            if !query.isEmpty { navigator.reset() }
        }
        .onChange(of: app.pendingOpen, initial: true) {
            guard let item = app.pendingOpen else { return }
            navigator.open(item)
            app.pendingOpen = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            SearchView(query: trimmed)
        } else {
            switch selection {
            case .section(let key):
                if let section = app.sections.first(where: { $0.key == key }) {
                    LibraryView(section: section).id(key)
                } else {
                    HomeView()
                }
            default:
                HomeView()
            }
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            if !app.sections.isEmpty {
                Section("Libraries") {
                    ForEach(app.sections) { section in
                        Label(section.title, systemImage: section.symbol).tag(SidebarItem.section(section.key))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        .safeAreaInset(edge: .bottom) {
            if let server = app.server {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive")
                    Text(server.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption11)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .help("Connected to \(server.name) at \(server.baseURL.host() ?? "")")
            }
        }
    }
}

// MARK: - Before the library

struct SignInView: View {
    @Environment(AppModel.self) private var app
    let waitingURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                PlexxedMark(size: 52)
                Text("Plexxed").font(.hero).foregroundStyle(Theme.textPrimary)
            }
            .padding(.leading, -6)
            Text(waitingURL == nil
                 ? "Your Plex library, played straight from the file. Sign in with your Plex account to load your libraries."
                 : "Approve the sign-in in your browser. This window picks it up by itself.")
                .font(.body13)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 340, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let url = waitingURL {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Plex").font(.body13).foregroundStyle(Theme.textPrimary)
                }
                .padding(.top, 4)
                HStack(spacing: 18) {
                    SecondaryButton("Open the page again") { NSWorkspace.shared.open(url) }
                    TextButton("Cancel") { app.cancelSignIn() }
                }
            } else {
                PrimaryButton("Sign in with Plex", systemImage: "arrow.up.forward.app") { app.beginSignIn() }
                    .padding(.top, 4)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct ServerPickerView: View {
    @Environment(AppModel.self) private var app
    let servers: [PlexResource]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose a server").font(.hero).foregroundStyle(Theme.textPrimary)
            VStack(spacing: 6) {
                ForEach(servers) { server in
                    ServerRow(server: server) { Task { await app.connect(server) } }
                }
            }
            .frame(width: 380)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private struct ServerRow: View {
    let server: PlexResource
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive").font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.body13Strong).foregroundStyle(Theme.textPrimary)
                    Text(server.owned ? "Your server" : "Shared with you")
                        .font(.caption11)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(hovered ? Theme.surfaceHover : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
    }
}

struct StatusView: View {
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(message).font(.body13).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

struct FailureView: View {
    @Environment(AppModel.self) private var app
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Can't reach Plex").font(.hero).foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.body13)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                PrimaryButton("Try again", systemImage: "arrow.clockwise") {
                    Task { await app.discoverServers() }
                }
                TextButton("Sign out") { app.signOut() }
            }
            .padding(.top, 4)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
