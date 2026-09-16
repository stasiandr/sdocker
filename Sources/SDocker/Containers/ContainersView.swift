import AppKit
import SwiftUI

struct ContainersView: View {
    @Environment(ContainersStore.self) private var store
    @Binding var path: [Container.ID]
    @Binding var runRequest: RunPrefill?
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var onlyRunning = false
    @State private var removing: [Container] = []
    @State private var pruneMessage: String?
    @MainActor private static var openedOnLaunch = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Container.ID.self) { id in
                    ContainerDetailView(containerID: id)
                }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if store.containers.isEmpty && !store.isLoading {
                ContentUnavailableView {
                    Label("No Containers", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Run a container from an image to see it here.")
                } actions: {
                    Button("Run Container…") { runRequest = .init() }
                }
            } else {
                summary
                table
            }
        }
        .navigationTitle("Containers")
        .navigationSubtitle(store.containers.isEmpty ? "" : "\(store.runningCount) of \(store.containers.count) running")
        .searchable(text: $search, placement: .toolbar, prompt: "Search containers")
        .toolbar {
            ToolbarItemGroup {
                Button { runRequest = .init() } label: { Label("Run", systemImage: "play.rectangle") }
                    .help("Run a container from an image")
                Toggle(isOn: $onlyRunning) { Label("Only Running", systemImage: "line.3.horizontal.decrease") }
                    .help("Show only running containers")
                Button {
                    Task {
                        let reclaimed = await store.pruneStopped()
                        pruneMessage = "Removed stopped containers, reclaimed \(format(bytes: reclaimed))."
                    }
                } label: {
                    Label("Remove Stopped", systemImage: "wand.and.sparkles")
                }
                .help("Remove all stopped containers")
            }
        }
        .confirmationDialog(
            removing.count == 1 ? "Delete \(removing[0].name)?" : "Delete \(removing.count) containers?",
            isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })
        ) {
            let ids = removing.map(\.id)
            Button("Delete", role: .destructive) { Task { await store.remove(ids) } }
            Button("Delete with Anonymous Volumes", role: .destructive) { Task { await store.remove(ids, volumes: true) } }
        } message: {
            Text(removing.contains { $0.state.isActive } ? "Running containers are stopped first." : "")
        }
        .alert("Containers", isPresented: Binding(get: { pruneMessage != nil }, set: { if !$0 { pruneMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(pruneMessage ?? "")
        }
        .task {
            while !Task.isCancelled {
                await store.refresh()
                // `-open <name>` opens a container on launch, for scripted screenshots.
                if let name = UserDefaults.standard.string(forKey: "open"), !Self.openedOnLaunch,
                   let c = store.containers.first(where: { $0.name == name }) {
                    Self.openedOnLaunch = true
                    path = [c.id]
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 24) {
            SummaryStat(title: "Running", value: "\(store.runningCount)")
            SummaryStat(title: "Stopped", value: "\(store.containers.count - store.runningCount)")
            SummaryStat(title: "CPU", value: percent(store.totalCPU))
            SummaryStat(title: "Memory", value: format(bytes: store.totalMemory))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Table

    /// A table row: a compose project, or a container (top-level or inside a project).
    struct Row: Identifiable {
        let id: String
        let container: Container?
        let project: String?
        var children: [Row] = []
    }

    private var rows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = store.containers.filter { c in
            (!onlyRunning || c.state.isActive)
                && (query.isEmpty || c.name.lowercased().contains(query) || c.image.lowercased().contains(query)
                    || c.shortID.hasPrefix(query) || (c.project?.lowercased().contains(query) ?? false))
        }
        var result: [Row] = []
        var projects: [String: Int] = [:]
        for c in visible {
            if let project = c.project {
                if let index = projects[project] {
                    result[index].children.append(Row(id: c.id, container: c, project: nil))
                } else {
                    projects[project] = result.count
                    result.append(Row(id: "project:" + project, container: nil, project: project,
                                      children: [Row(id: c.id, container: c, project: nil)]))
                }
            } else {
                result.append(Row(id: c.id, container: c, project: nil))
            }
        }
        return result
    }

    private var table: some View {
        Table(of: Row.self, selection: $selection) {
            TableColumn("Name") { row in
                if let c = row.container {
                    HStack(spacing: 8) {
                        StateDot(state: c.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.service ?? c.name).fontWeight(.medium).lineLimit(1)
                            Text(c.image).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(.vertical, 2)
                } else if let project = row.project {
                    let running = row.children.filter { $0.container?.state == .running }.count
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                        Text(project).fontWeight(.semibold)
                        Text("\(running)/\(row.children.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Status") { row in
                if let c = row.container {
                    Text(c.status).foregroundStyle(c.state == .running ? .primary : .secondary).lineLimit(1)
                }
            }
            .width(min: 80, ideal: 120)

            TableColumn("Ports") { row in
                if let c = row.container {
                    PortLinks(ports: c.ports, active: c.state == .running)
                }
            }
            .width(min: 70, ideal: 100)

            TableColumn("CPU") { row in
                if let id = row.container?.id, let s = store.stats[id] {
                    Text(percent(s.cpuPercent)).monospacedDigit().foregroundStyle(.secondary)
                } else if let children = Optional(row.children), !children.isEmpty {
                    let total = children.compactMap { store.stats[$0.id]?.cpuPercent }.reduce(0, +)
                    Text(percent(total)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .width(ideal: 60)

            TableColumn("Memory") { row in
                if let id = row.container?.id, let s = store.stats[id] {
                    Text(format(bytes: s.memoryUsed)).monospacedDigit().foregroundStyle(.secondary)
                } else if !row.children.isEmpty {
                    let total = row.children.compactMap { store.stats[$0.id]?.memoryUsed }.reduce(0, +)
                    Text(format(bytes: total)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .width(ideal: 80)

            TableColumn("Created") { row in
                if let c = row.container {
                    Text(relative(c.created)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .width(min: 80, ideal: 110)

            TableColumn("") { row in
                ActionButtons(containers: row.container.map { [$0] } ?? row.children.compactMap(\.container),
                              onDelete: { removing = $0 })
            }
            .width(min: 64, ideal: 64, max: 64)
        } rows: {
            ForEach(rows) { row in
                if row.children.isEmpty {
                    TableRow(row)
                } else {
                    DisclosureTableRow(row, isExpanded: .constant(true)) {
                        ForEach(row.children) { TableRow($0) }
                    }
                }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let selected = containers(for: ids)
            if selected.count == 1, let c = selected.first {
                Button("Open") { path = [c.id] }
                if c.state == .running {
                    Button("Open Terminal") { store.openTerminal(c) }
                    ForEach(c.ports, id: \.self) { port in
                        Button("Open localhost:\(port.PublicPort!)") { openPort(port) }
                    }
                }
                Button("Copy ID") { copy(c.id) }
                Divider()
            }
            if selected.contains(where: { !$0.state.isActive }) {
                Button("Start") { Task { await store.perform(.start, on: selected.filter { !$0.state.isActive }.map(\.id)) } }
            }
            if selected.contains(where: { $0.state.isActive }) {
                Button("Stop") { Task { await store.perform(.stop, on: selected.filter { $0.state.isActive }.map(\.id)) } }
                Button("Restart") { Task { await store.perform(.restart, on: selected.map(\.id)) } }
            }
            if selected.contains(where: { $0.state == .running }) {
                Button("Pause") { Task { await store.perform(.pause, on: selected.filter { $0.state == .running }.map(\.id)) } }
            }
            if selected.contains(where: { $0.state == .paused }) {
                Button("Resume") { Task { await store.perform(.unpause, on: selected.filter { $0.state == .paused }.map(\.id)) } }
            }
            Divider()
            Button("Delete…", role: .destructive) { removing = selected }
                .disabled(selected.isEmpty)
        } primaryAction: { ids in
            if let c = containers(for: ids).first, ids.count == 1, !ids.first!.hasPrefix("project:") { path = [c.id] }
        }
        .onDeleteCommand { removing = containers(for: selection) }
    }

    /// Selected containers; a selected project stands for all of its containers.
    private func containers(for ids: Set<String>) -> [Container] {
        store.containers.filter { c in ids.contains(c.id) || c.project.map { ids.contains("project:" + $0) } == true }
    }

    private func openPort(_ port: ContainerSummary.Port) {
        if let url = URL(string: "http://localhost:\(port.PublicPort!)") { NSWorkspace.shared.open(url) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct SummaryStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

struct StateDot: View {
    let state: Container.State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(.black.opacity(0.1)))
            .help(state.rawValue.capitalized)
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .paused: .yellow
        case .restarting: .orange
        case .created: .blue
        case .exited, .removing: .gray
        case .dead: .red
        }
    }
}

struct PortLinks: View {
    let ports: [ContainerSummary.Port]
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ports.prefix(3), id: \.self) { port in
                let label = "\(port.PublicPort!):\(port.PrivatePort)"
                if active, port.Type == "tcp", let url = URL(string: "http://localhost:\(port.PublicPort!)") {
                    Link(label, destination: url)
                        .help("Open \(url.absoluteString)")
                } else {
                    Text(label).foregroundStyle(.secondary)
                }
            }
            if ports.count > 3 {
                Text("+\(ports.count - 3)").foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
    }
}

private struct ActionButtons: View {
    @Environment(ContainersStore.self) private var store
    let containers: [Container]
    let onDelete: ([Container]) -> Void

    var body: some View {
        let ids = containers.map(\.id)
        HStack(spacing: 10) {
            if ids.contains(where: store.busy.contains) {
                ProgressView().controlSize(.small)
            } else if containers.contains(where: { $0.state.isActive }) {
                Button { Task { await store.perform(.stop, on: containers.filter { $0.state.isActive }.map(\.id)) } } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop")
            } else {
                Button { Task { await store.perform(.start, on: ids) } } label: {
                    Image(systemName: "play.fill")
                }
                .help("Start")
            }
            Button { onDelete(containers) } label: { Image(systemName: "trash") }
                .help("Delete")
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
