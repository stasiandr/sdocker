import SwiftUI

struct NetworksView: View {
    @Environment(NetworksStore.self) private var store
    @State private var selection: Set<Network.ID> = []
    @State private var search = ""
    @State private var showInspector = true
    @State private var isCreating = false
    @State private var removing: [Network] = []
    @State private var message: String?

    var body: some View {
        table
            .navigationTitle("Networks")
            .navigationSubtitle("\(store.networks.count) networks")
            .searchable(text: $search, placement: .toolbar, prompt: "Search networks")
            .inspector(isPresented: $showInspector) {
                Group {
                    if selection.count == 1, let network = store.networks.first(where: { selection.contains($0.id) }) {
                        NetworkDetail(network: network)
                    } else {
                        ContentUnavailableView("No Selection", systemImage: "network",
                                               description: Text("Select a network to see its containers."))
                    }
                }
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button { isCreating = true } label: { Label("Create", systemImage: "plus") }
                        .help("Create a bridge network")
                    Button {
                        Task {
                            let removed = await store.pruneUnused()
                            message = removed.isEmpty ? "No unused networks." : "Removed \(removed.joined(separator: ", "))."
                        }
                    } label: {
                        Label("Remove Unused", systemImage: "wand.and.sparkles")
                    }
                    .help("Remove custom networks no container uses")
                    Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r")
                }
                ToolbarItem {
                    Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                        .keyboardShortcut("i")
                }
            }
            .sheet(isPresented: $isCreating) { CreateNetworkSheet() }
            .confirmationDialog(
                removing.count == 1 ? "Delete network \(removing[0].name)?" : "Delete \(removing.count) networks?",
                isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })
            ) {
                let ids = removing.map(\.id)
                Button("Delete", role: .destructive) { Task { await store.remove(ids) } }
            }
            .alert("Networks", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            } message: {
                Text(message ?? "")
            }
            .task {
                await store.refresh()
                if let name = UserDefaults.standard.string(forKey: "select"), let n = store.networks.first(where: { $0.name == name }) {
                    selection = [n.id]
                }
            }
    }

    private var visible: [Network] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.networks }
        return store.networks.filter { $0.name.lowercased().contains(query) || $0.subnets.contains { $0.contains(query) } }
    }

    private var table: some View {
        Table(visible, selection: $selection) {
            TableColumn("Name") { n in
                HStack(spacing: 8) {
                    Image(systemName: n.isBuiltIn ? "network.badge.shield.half.filled" : "network")
                        .foregroundStyle(n.isBuiltIn ? Color.secondary : Color.accentColor)
                    Text(n.name).lineLimit(1)
                    if n.isInternal {
                        Text("Internal").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Driver") { n in Text(n.driver).foregroundStyle(.secondary) }
                .width(ideal: 70)
            TableColumn("Subnet") { n in
                Text(n.subnets.joined(separator: ", ")).font(.body.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Gateway") { n in
                Text(n.gateways.joined(separator: ", ")).font(.body.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 100)
            TableColumn("Containers") { n in
                let count = store.members[n.id]?.count ?? 0
                Text(count == 0 ? "—" : "\(count)").monospacedDigit().foregroundStyle(count == 0 ? .tertiary : .primary)
            }
            .width(ideal: 80)
            TableColumn("Created") { n in
                Text(n.created.map(relative) ?? "—").foregroundStyle(.secondary)
            }
            .width(ideal: 120)
        }
        .contextMenu(forSelectionType: Network.ID.self) { ids in
            let selected = store.networks.filter { ids.contains($0.id) && !$0.isBuiltIn }
            Button("Delete…", role: .destructive) { removing = selected }
                .disabled(selected.isEmpty)
        }
        .onDeleteCommand { removing = store.networks.filter { selection.contains($0.id) && !$0.isBuiltIn } }
    }
}

private struct NetworkDetail: View {
    @Environment(NetworksStore.self) private var store
    let network: Network

    var body: some View {
        Form {
            Section {
                LabeledContent("Driver", value: network.driver)
                LabeledContent("Scope", value: network.scope)
                if !network.subnets.isEmpty {
                    LabeledContent("Subnet") { Text(network.subnets.joined(separator: "\n")).font(.body.monospaced()) }
                }
                if !network.gateways.isEmpty {
                    LabeledContent("Gateway") { Text(network.gateways.joined(separator: "\n")).font(.body.monospaced()) }
                }
                LabeledContent("Internal", value: network.isInternal ? "Yes" : "No")
                if let project = network.project { LabeledContent("Compose project", value: project) }
                LabeledContent("ID") {
                    Text(String(network.id.prefix(12))).font(.body.monospaced()).textSelection(.enabled)
                }
            } header: {
                Text(network.name).font(.title3.weight(.semibold))
            }
            Section("Containers") {
                let members = (store.members[network.id] ?? []).sorted { $0.name < $1.name }
                if members.isEmpty {
                    Text("No containers").foregroundStyle(.secondary)
                }
                ForEach(members, id: \.name) { member in
                    LabeledContent(member.name) {
                        Text(member.ip.isEmpty ? "—" : member.ip).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CreateNetworkSheet: View {
    @Environment(NetworksStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subnet = ""
    @State private var gateway = ""
    @State private var isInternal = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("my-network"))
                TextField("Subnet", text: $subnet, prompt: Text("Automatic, e.g. 172.30.0.0/16"))
                TextField("Gateway", text: $gateway, prompt: Text("Automatic"))
                Toggle("Internal (no outside access)", isOn: $isInternal)
            }
            .formStyle(.grouped)
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.callout).lineLimit(2) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    Task {
                        do {
                            try await store.create(name: name, subnet: subnet, gateway: gateway, isInternal: isInternal)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440, height: 300)
    }
}
