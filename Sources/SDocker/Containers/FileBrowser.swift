import SwiftUI

/// Navigable listing of a filesystem inside Docker: a container's or a volume's.
struct FileBrowser: View {
    let root: String
    let list: (String) async throws -> [FileEntry]
    let download: ((FileEntry) -> Void)?

    @State private var path: String
    @State private var entries: [FileEntry] = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var selection: FileEntry.ID?

    init(root: String = "/", list: @escaping (String) async throws -> [FileEntry], download: ((FileEntry) -> Void)? = nil) {
        self.root = root
        self.list = list
        self.download = download
        _path = State(initialValue: root)
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            if let error {
                ContentUnavailableView("Can't List Files", systemImage: "folder.badge.questionmark", description: Text(error))
            } else {
                Table(entries, selection: $selection) {
                    TableColumn("Name") { entry in
                        Label {
                            Text(entry.name).lineLimit(1)
                        } icon: {
                            Image(systemName: icon(entry)).foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                        }
                    }
                    .width(min: 200, ideal: 360)
                    TableColumn("Size") { entry in
                        Text(entry.kind == .directory ? "—" : format(bytes: entry.size))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(ideal: 90)
                    TableColumn("Modified") { entry in
                        Text(entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 160)
                }
                .contextMenu(forSelectionType: FileEntry.ID.self) { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }) {
                        if entry.kind == .directory || entry.kind == .link {
                            Button("Open") { path = entry.path }
                        }
                        if let download {
                            Button("Save to Mac…") { download(entry) }
                        }
                    }
                } primaryAction: { ids in
                    if let entry = entries.first(where: { ids.contains($0.id) }), entry.kind != .file {
                        path = entry.path
                    }
                }
                .overlay {
                    if isLoading && entries.isEmpty { ProgressView() }
                    else if !isLoading && entries.isEmpty { Text("Empty folder").foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: path) { await load() }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button { path = parent } label: { Image(systemName: "chevron.up") }
                .disabled(path == root)
                .help("Enclosing folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(crumbs, id: \.path) { crumb in
                        if crumb.path != root { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                        Button(crumb.name) { path = crumb.path }
                            .buttonStyle(.borderless)
                            .foregroundStyle(crumb.path == path ? .primary : .secondary)
                    }
                }
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var crumbs: [(name: String, path: String)] {
        var result = [(name: root == "/" ? "/" : (root as NSString).lastPathComponent, path: root)]
        let relative = path.dropFirst(root.count).split(separator: "/")
        var current = root
        for part in relative {
            current = current.hasSuffix("/") ? current + part : current + "/" + part
            result.append((String(part), current))
        }
        return result
    }

    private var parent: String {
        let up = (path as NSString).deletingLastPathComponent
        return up.count < root.count ? root : up
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await list(path)
            error = nil
        } catch is CancellationError {
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
    }

    private func icon(_ entry: FileEntry) -> String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .link: "arrow.up.forward.square"
        case .file: "doc"
        case .other: "questionmark.square.dashed"
        }
    }
}
