import SwiftUI

struct BuildsView: View {
    @Environment(BuildsStore.self) private var store
    @Binding var path: [BuildItem.ID]
    @Binding var newBuild: BuildRequest?
    @State private var selection: Set<BuildItem.ID> = []
    @State private var search = ""
    @MainActor private static var startedLaunchBuild = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: BuildItem.ID.self) { id in
                    BuildDetailView(itemID: id, onRebuild: { newBuild = $0 })
                }
        }
    }

    private var content: some View {
        Group {
            if store.items.isEmpty && !store.isLoading {
                ContentUnavailableView {
                    Label("No Builds", systemImage: "hammer")
                } description: {
                    Text("Builds run here or with `docker buildx build` in the terminal show up in this list.")
                } actions: {
                    Button("New Build…") { newBuild = BuildRequest.blank }
                }
            } else {
                table
            }
        }
        .navigationTitle("Builds")
        .navigationSubtitle(store.runningCount > 0 ? "\(store.runningCount) running" : "")
        .searchable(text: $search, placement: .toolbar, prompt: "Search builds")
        .toolbar {
            ToolbarItemGroup {
                Button { newBuild = BuildRequest.blank } label: { Label("New Build", systemImage: "hammer") }
                    .help("Build an image from a Dockerfile (⌘B)")
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
            }
        }
        .task {
            // `-build <folder>` starts a build on launch, for scripted screenshots.
            if let folder = UserDefaults.standard.string(forKey: "build"), !Self.startedLaunchBuild {
                Self.startedLaunchBuild = true
                path = [store.start(BuildRequest(context: URL(fileURLWithPath: folder), tags: ["sdtest:live"])).id.uuidString]
            }
        }
        .task {
            // Pick up builds started from the terminal while this list is on screen.
            while !Task.isCancelled {
                await store.refresh()
                if let ref = UserDefaults.standard.string(forKey: "open"), path.isEmpty,
                   store.items.contains(where: { $0.id == ref }) {
                    path = [ref]
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var table: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Table(visibleItems, selection: $selection) {
                TableColumn("Build") { item in
                    HStack(spacing: 10) {
                        StatusIcon(status: item.status)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            if let ref = item.ref {
                                Text(ref.prefix(12)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .width(min: 240, ideal: 380)

                TableColumn("Status") { item in
                    Text(item.status.title).foregroundStyle(item.status.color)
                }
                .width(ideal: 90)

                TableColumn("Steps") { item in
                    Text(item.cachedSteps > 0 ? "\(item.totalSteps) · \(item.cachedSteps) cached" : "\(item.totalSteps)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(ideal: 110)

                TableColumn("Duration") { item in
                    Text(item.duration.map(format(duration:)) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(ideal: 80)

                TableColumn("Started") { item in
                    Text(item.started.map(relative) ?? "—").foregroundStyle(.secondary)
                }
                .width(ideal: 130)
            }
            .contextMenu(forSelectionType: BuildItem.ID.self) { ids in
                let items = store.items.filter { ids.contains($0.id) }
                if items.count == 1, let item = items.first {
                    Button("Open") { path = [item.id] }
                    if let session = store.session(item.sessionID), session.status == .running {
                        Button("Cancel Build") { store.cancel(session) }
                    }
                }
                let refs = items.filter { $0.status != .running }.compactMap(\.ref)
                Button("Delete from History", role: .destructive) { Task { await store.remove(refs: refs) } }
                    .disabled(refs.isEmpty)
            } primaryAction: { ids in
                if let id = ids.first { path = [id] }
            }
        }
    }

    private var visibleItems: [BuildItem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.items }
        return store.items.filter { $0.name.lowercased().contains(query) || ($0.ref?.hasPrefix(query) ?? false) }
    }
}

extension BuildRequest {
    static var blank: BuildRequest { BuildRequest(context: URL(fileURLWithPath: NSHomeDirectory())) }
}

extension BuildStatus {
    var title: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .canceled: "Canceled"
        }
    }

    var color: Color {
        switch self {
        case .running: .blue
        case .completed: .secondary
        case .failed: .red
        case .canceled: .orange
        }
    }
}

struct StatusIcon: View {
    let status: BuildStatus

    var body: some View {
        Group {
            switch status {
            case .running: ProgressView().controlSize(.small)
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            case .canceled: Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
            }
        }
        .font(.title3)
        .frame(width: 20, height: 20)
    }
}
