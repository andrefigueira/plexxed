import SwiftUI

// MARK: - Buttons

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.quick, value: configuration.isPressed)
    }
}

/// The one filled action per screen.
struct PrimaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    init(_ title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .bold))
                Text(title).font(.body13Strong)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.body13Strong)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(hovered ? Theme.surfaceHover : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 36, height: 36)
                .background(hovered ? Theme.surfaceHover : Theme.surface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Plain text that acts as a link-style button.
struct TextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body13Strong)
                .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Dropdown

/// A custom dropdown: a quiet button that opens a short list with a check on the current choice.
struct Dropdown<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @State private var open = false
    @State private var hovered = false

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? ""
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(currentLabel).font(.body13)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(hovered || open ? Theme.surfaceHover : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityValue(currentLabel)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    MenuRow(title: option.label, selected: option.value == selection) {
                        selection = option.value
                        open = false
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 200)
        }
    }
}

struct MenuRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body13).lineLimit(1)
                    if let detail, !detail.isEmpty, detail != title {
                        Text(detail).font(.caption11).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 28)
            .background(hovered ? Theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Progress and state marks

struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityLabel("\(Int(fraction * 100)) percent watched")
    }
}

struct WatchedMark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 20, height: 20)
            .background(Theme.background, in: Circle())
            .accessibilityLabel("Watched")
    }
}

// MARK: - Cards

/// A 2:3 poster with its title underneath. Used in grids and rows.
struct PosterCard: View {
    let item: PlexItem
    @Environment(AppModel.self) private var app
    @State private var hovered = false

    private var caption: String {
        if item.isShow, let left = item.unwatchedEpisodes, (item.viewedLeafCount ?? 0) > 0 {
            return left == 1 ? "1 episode left" : "\(left) episodes left"
        }
        return item.caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlexImage(app.server?.image(item.posterPath, width: ArtSize.poster.width, height: ArtSize.poster.height))
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressLine(fraction: progress).padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isWatched { WatchedMark().padding(6) }
                }
                .scaleEffect(hovered ? 1.03 : 1)
                .animation(.quick, value: hovered)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.headline)
                    .font(.body13)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(caption.isEmpty ? " " : caption)
                    .font(.caption11)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { ItemMenu(item: item) }
        .accessibilityElement(children: .combine)
    }
}

/// A 16:9 card that plays on click. Used for Continue Watching.
struct LandscapeCard: View {
    let item: PlexItem
    var width: CGFloat = 300
    @Environment(AppModel.self) private var app
    @State private var hovered = false

    private var caption: String {
        var parts: [String] = []
        if let label = item.episodeLabel { parts.append(label) }
        if let remaining = item.remainingMs { parts.append(Format.remaining(ms: remaining)) }
        else if let runtime = Format.runtime(ms: item.duration) { parts.append(runtime) }
        return parts.joined(separator: "   ")
    }

    var body: some View {
        Button { app.play(item) } label: {
            VStack(alignment: .leading, spacing: 8) {
                PlexImage(app.server?.image(item.landscapePath, width: ArtSize.landscape.width, height: ArtSize.landscape.height))
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Theme.background, in: Circle())
                            .opacity(hovered ? 1 : 0)
                    }
                    .overlay(alignment: .bottom) {
                        if let progress = item.progress {
                            ProgressLine(fraction: progress).padding(10)
                        }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.headline)
                        .font(.body13)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption11)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.quick, value: hovered)
        .contextMenu { ItemMenu(item: item, showDetails: true) }
        .accessibilityLabel("\(item.headline), \(caption)")
    }
}

struct ItemMenu: View {
    let item: PlexItem
    var showDetails = false
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator: Navigator?

    var body: some View {
        if item.isPlayable {
            Button(item.progress != nil ? "Resume" : "Play") { app.play(item) }
            if item.progress != nil {
                Button("Play from Beginning") { app.play(item, fromStart: true) }
            }
        }
        if showDetails, let navigator {
            Button(item.isEpisode ? "Go to Show" : "Details") { navigator.open(item) }
        }
        Divider()
        Button(item.isWatched ? "Mark as Unwatched" : "Mark as Watched") {
            app.setWatched(item, !item.isWatched)
        }
    }
}

// MARK: - Artwork

/// A show or movie's title logo when Plex has one, otherwise its name set in type.
struct TitleArt: View {
    let title: String
    let logo: ImageRequest?
    var maxWidth: CGFloat = 400
    var maxHeight: CGFloat = 120

    @State private var image: CGImage?

    init(title: String, logo: ImageRequest?, maxWidth: CGFloat = 400, maxHeight: CGFloat = 120) {
        self.title = title
        self.logo = logo
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        _image = State(initialValue: logo.flatMap { ImagePipeline.shared.cached($0.cacheKey) })
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
                    .accessibilityLabel(title)
                    .transition(.opacity)
            } else {
                Text(title)
                    .font(.hero)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .task(id: logo?.cacheKey) {
            guard let logo, image == nil else { return }
            let loaded = await ImagePipeline.shared.image(for: logo)
            guard !Task.isCancelled, let loaded else { return }
            withAnimation(.calm) { image = loaded }
        }
    }
}

/// Full-width artwork that fades into the page and extends under the sidebar.
struct Backdrop: View {
    let request: ImageRequest?
    let height: CGFloat

    var body: some View {
        PlexImage(request, placeholder: Theme.background)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0.45), .init(color: .clear, location: 1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .backgroundExtensionEffect()
            .accessibilityHidden(true)
    }
}

/// Values separated by space alone.
struct MetaLine: View {
    let values: [String]
    var font: Font = .body13

    var body: some View {
        HStack(spacing: 16) {
            ForEach(values, id: \.self) { value in
                Text(value)
            }
        }
        .font(font)
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
    }
}
