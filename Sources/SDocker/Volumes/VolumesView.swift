import AppKit
import SwiftUI

struct VolumesView: View {
    @Environment(VolumesStore.self) private var store
    @State private var path: [Volume.ID] = []
    @State private var selection: Set<Volume.ID> = []
    @State private var search = ""
    @State private var isCreating = false
    @State private var newName = ""
    @State private var removing: [Volume] = []
    @State private var confirmPrune = false
    @State private var message: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Volume.ID.self) { VolumeDetailView(name: $0) }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if store.volumes.isEmpty && !store.isLoading {
                ContentUnavailableView {
                    Label("No Volumes", systemImage: "externaldrive")
                } description: {
                    Text("Volumes keep container data across restarts and rebuilds.")
                } actions: {
                    Button("Create Volume…") { isCreating = true }
                }
            } else {
                HStack(spacing: 24) {
                    SummaryStat(title: "Volumes", value: "\(store.volumes.count)")
                    SummaryStat(title: "In use", value: "\(store.volumes.filter { store.usedBy[$0.name] != nil }.count)")
                    SummaryStat(title: "Total size", value: format(bytes: store.totalSize))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                table
            }
        }
        .navigationTitle("Volumes")
        .searchable(text: $search, placement: .toolbar, prompt: "Search volumes")
        .toolbar {
            ToolbarItemGroup {
                Button { isCreating = true } label: { Label("Create", systemImage: "plus") }
                    .help("Create a volume")
                Button { confirmPrune = true } label: { Label("Remove Unused", systemImage: "wand.and.sparkles") }
                    .help("Remove volumes no container uses")
                Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
            }
        }
        .alert("New Volume", isPresented: $isCreating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName
                newName = ""
                Task { await store.create(name: name) }
            }
        }
        .confirmationDialog(
            removing.count == 1 ? "Delete volume \(removing[0].name)?" : "Delete \(removing.count) volumes?",
            isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })
        ) {
            let names = removing.map(\.name)
            Button("Delete", role: .destructive) { Task { await store.remove(names) } }
        } message: {
            Text("The data in them is deleted permanently.")
        }
        .confirmationDialog("Remove all unused volumes?", isPresented: $confirmPrune) {
            Button("Remove Unused Volumes", role: .destructive) {
                Task { message = "Reclaimed \(format(bytes: await store.pruneUnused()))." }
            }
        } message: {
            Text("Every volume that no container (running or stopped) uses is deleted with its data.")
        }
        .alert("Volumes", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
        .task {
            await store.refresh()
            if let name = UserDefaults.standard.string(forKey: "open"), store.volumes.contains(where: { $0.name == name }) {
                path = [name]
            }
        }
    }

    private var visible: [Volume] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.volumes }
        return store.volumes.filter {
            $0.name.lowercased().contains(query) || (store.usedBy[$0.name] ?? []).contains { $0.lowercased().contains(query) }
        }
    }

    private var table: some View {
        Table(visible, selection: $selection) {
            TableColumn("Name") { v in
                HStack(spacing: 8) {
                    Image(systemName: store.usedBy[v.name] == nil ? "externaldrive" : "externaldrive.fill")
                        .foregroundStyle(store.usedBy[v.name] == nil ? Color.secondary : Color.accentColor)
                    Text(v.isAnonymous ? String(v.name.prefix(12)) + "…" : v.name)
                        .foregroundStyle(v.isAnonymous ? .secondary : .primary)
                        .lineLimit(1)
                        .help(v.name)
                }
            }
            .width(min: 180, ideal: 280)
            TableColumn("Used by") { v in
                Text(store.usedBy[v.name]?.joined(separator: ", ") ?? "—")
                    .foregroundStyle(store.usedBy[v.name] == nil ? .tertiary : .primary)
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 180)
            TableColumn("Size") { v in
                Text(v.size >= 0 ? format(bytes: v.size) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(ideal: 80)
            TableColumn("Created") { v in
                Text(v.created.map(relative) ?? "—").foregroundStyle(.secondary)
            }
            .width(ideal: 120)
            TableColumn("Driver") { v in Text(v.driver).foregroundStyle(.secondary) }
                .width(ideal: 60)
        }
        .contextMenu(forSelectionType: Volume.ID.self) { names in
            let selected = store.volumes.filter { names.contains($0.name) }
            if selected.count == 1, let v = selected.first {
                Button("Browse Files") { path = [v.name] }
                Button("Copy Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(v.name, forType: .string)
                }
                Divider()
            }
            Button("Delete…", role: .destructive) { removing = selected }
                .disabled(selected.isEmpty || selected.contains { store.usedBy[$0.name] != nil })
        } primaryAction: { names in
            if let name = names.first { path = [name] }
        }
        .onDeleteCommand { removing = store.volumes.filter { selection.contains($0.name) && store.usedBy[$0.name] == nil } }
    }
}

private struct VolumeDetailView: View {
    @Environment(VolumesStore.self) private var store
    let name: String
    @State private var tab = 0

    var body: some View {
        let volume = store.volumes.first { $0.name == name }
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    HStack(spacing: 14) {
                        if let size = volume?.size, size >= 0 { Label(format(bytes: size), systemImage: "internaldrive") }
                        if let created = volume?.created { Label(relative(created), systemImage: "calendar") }
                        let users = store.usedBy[name] ?? []
                        Label(users.isEmpty ? "Not in use" : users.joined(separator: ", "), systemImage: "shippingbox")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Picker("", selection: $tab) {
                Text("Files").tag(0)
                Text("Info").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)
            Divider()

            if tab == 0 {
                FileBrowser(
                    root: "/volume",
                    list: { try await store.listFiles(name, path: $0) },
                    download: { entry in Task { await store.download(name, path: entry.path) } }
                )
            } else if let volume {
                Form {
                    LabeledContent("Driver", value: volume.driver)
                    LabeledContent("Mount point in VM") { Text(volume.mountpoint).textSelection(.enabled) }
                    if let project = volume.project { LabeledContent("Compose project", value: project) }
                    ForEach(volume.labels.sorted { $0.key < $1.key }, id: \.key) { key, value in
                        LabeledContent(key) { Text(value).textSelection(.enabled) }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .navigationTitle(volume?.isAnonymous == true ? String(name.prefix(12)) : name)
    }
}
