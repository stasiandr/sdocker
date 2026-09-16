import AppKit
import SwiftUI

struct ImagesView: View {
    @Environment(ImagesStore.self) private var store
    @State private var selection: Set<ImageRow.ID> = []
    /// `-select <repository>` preselects an image, for scripted screenshots.
    private let initialSelection = UserDefaults.standard.string(forKey: "select")
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ImageRow.created, order: .reverse)]
    @State private var showInspector = true
    @State private var isPulling = false
    @State private var tagging: ImageRow?
    @State private var removing: [ImageRow] = []
    @State private var pruneMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.rows.isEmpty && !store.isLoading {
                ContentUnavailableView {
                    Label("No Images", systemImage: "shippingbox")
                } description: {
                    Text("Pull an image from Docker Hub or build one from a Dockerfile.")
                } actions: {
                    Button("Pull Image…") { isPulling = true }
                }
            } else {
                summary
                table
            }
            ForEach(store.pulls) { PullBar(pull: $0) }
        }
        .navigationTitle("Images")
        .navigationSubtitle(store.rows.isEmpty ? "" : "\(store.imageCount) images · \(format(bytes: store.totalSize))")
        .searchable(text: $search, placement: .toolbar, prompt: "Search images")
        .inspector(isPresented: $showInspector) {
            Group {
                if let row = inspected {
                    ImageDetailView(row: row)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "shippingbox",
                                           description: Text("Select an image to see its layers and config."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 600)
        }
        .toolbar { toolbar }
        .sheet(isPresented: $isPulling) { PullSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .pullImage)) { _ in isPulling = true }
        .sheet(item: $tagging) { TagSheet(row: $0) }
        .confirmationDialog(
            removing.count == 1 ? "Remove \(removing[0].reference)?" : "Remove \(removing.count) images?",
            isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })
        ) {
            let rows = removing
            Button("Remove", role: .destructive) { Task { await store.remove(rows) } }
            if rows.contains(where: \.inUse) {
                Button("Force Remove", role: .destructive) { Task { await store.remove(rows, force: true) } }
            }
        } message: {
            Text(removing.contains(where: \.inUse)
                 ? "Some of these images are used by containers."
                 : "Untagged layers that no other image uses are deleted.")
        }
        .alert("Images", isPresented: Binding(get: { pruneMessage != nil }, set: { if !$0 { pruneMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(pruneMessage ?? "")
        }
        .task {
            await store.refresh()
            if let name = initialSelection, let row = store.rows.first(where: { $0.repository == name }) {
                selection = [row.id]
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 24) {
            Stat(title: "Images", value: "\(store.imageCount)")
            Stat(title: "Total size", value: format(bytes: store.totalSize))
            Stat(title: "In use", value: "\(Set(store.rows.filter(\.inUse).map(\.imageID)).count)")
            Stat(title: "Dangling", value: store.danglingSize > 0 ? format(bytes: store.danglingSize) : "None")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var table: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.repository) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.isDangling ? "shippingbox" : "shippingbox.fill")
                        .foregroundStyle(row.isDangling ? Color.secondary : Color.accentColor)
                    Text(row.repository)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.isDangling ? .secondary : .primary)
                    if row.inUse {
                        Text("In use")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Tag", value: \.tag) { row in
                Text(row.tag).foregroundStyle(row.isDangling ? .secondary : .primary).lineLimit(1)
            }
            .width(min: 60, ideal: 110)

            TableColumn("Image ID", value: \.imageID) { row in
                Text(row.shortID).font(.body.monospaced()).foregroundStyle(.secondary)
            }
            .width(ideal: 110)

            TableColumn("Platform") { row in
                Text(row.platforms.map { $0.replacingOccurrences(of: "linux/", with: "") }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(ideal: 90)

            TableColumn("Created", value: \.created) { row in
                Text(relative(row.created)).foregroundStyle(.secondary)
            }
            .width(ideal: 120)

            TableColumn("Size", value: \.size) { row in
                Text(format(bytes: row.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(ideal: 80)
        }
        .contextMenu(forSelectionType: ImageRow.ID.self) { ids in
            let rows = store.rows.filter { ids.contains($0.id) }
            if rows.count == 1, let row = rows.first {
                Button("Copy Reference") { copy(row.reference) }
                Button("Copy Image ID") { copy(row.imageID) }
                Button("Run…") { NotificationCenter.default.post(name: .runImage, object: row.reference) }
                Button("Tag…") { tagging = row }
                if !row.isDangling {
                    Button("Pull Again") { store.pull(row.reference) }
                }
                Divider()
            }
            Button("Remove…", role: .destructive) { removing = rows }
                .disabled(rows.isEmpty)
        } primaryAction: { ids in
            selection = ids
            showInspector = true
        }
        .onDeleteCommand { removing = selectedRows }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { isPulling = true } label: { Label("Pull", systemImage: "arrow.down.circle") }
                .help("Pull an image (⌘N)")
            Button {
                Task {
                    let reclaimed = await store.pruneDangling()
                    pruneMessage = "Reclaimed \(format(bytes: reclaimed))."
                }
            } label: {
                Label("Prune Dangling", systemImage: "wand.and.sparkles")
            }
            .help("Remove untagged images no container uses")
            Button { Task { await store.refresh() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
        }
        ToolbarItem {
            Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                .keyboardShortcut("i")
        }
    }

    private var visibleRows: [ImageRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = query.isEmpty ? store.rows : store.rows.filter {
            $0.repository.lowercased().contains(query) || $0.tag.lowercased().contains(query)
                || $0.shortID.hasPrefix(query)
        }
        return rows.sorted(using: sortOrder)
    }

    private var selectedRows: [ImageRow] {
        store.rows.filter { selection.contains($0.id) }
    }

    private var inspected: ImageRow? {
        selectedRows.count == 1 ? selectedRows.first : nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

private struct PullBar: View {
    @Environment(ImagesStore.self) private var store
    let pull: ImagesStore.Pull

    var body: some View {
        HStack(spacing: 10) {
            if let error = pull.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("\(pull.reference): \(error)").lineLimit(2)
                Spacer()
                Button("Dismiss") { store.dismiss(pull) }
            } else if pull.done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Pulled \(pull.reference)")
                Spacer()
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(pull.reference).fontWeight(.medium)
                        Text(pull.status).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let fraction = pull.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct PullSheet: View {
    @Environment(ImagesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var reference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Pull Image", systemImage: "arrow.down.circle").font(.headline)
            TextField("Image", text: $reference, prompt: Text("nginx:alpine, ghcr.io/owner/app:1.2"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Text("Without a tag, :latest is pulled. Images come from Docker Hub unless a registry is given.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Pull", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        store.pull(reference)
        dismiss()
    }
}

private struct TagSheet: View {
    @Environment(ImagesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let row: ImageRow
    @State private var reference = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Tag \(row.isDangling ? row.shortID : row.reference)", systemImage: "tag").font(.headline)
            TextField("New reference", text: $reference, prompt: Text("repository:tag"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Tag", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { reference = row.isDangling ? "" : row.repository + ":" }
    }

    private func submit() {
        let reference = reference
        Task { await store.tag(row, as: reference) }
        dismiss()
    }
}
