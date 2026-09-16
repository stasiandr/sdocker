import SwiftUI

struct ContentView: View {
    @Environment(EngineStore.self) private var engine
    @Environment(ContainersStore.self) private var containers
    @Environment(ImagesStore.self) private var images
    @Environment(VolumesStore.self) private var volumes
    @Environment(NetworksStore.self) private var networks
    @Environment(BuildsStore.self) private var builds
    @Environment(DiskStore.self) private var disk
    @Binding var section: SidebarItem
    @Binding var newBuild: BuildRequest?
    @Binding var runPrefill: RunPrefill?
    @State private var buildPath: [BuildItem.ID] = []
    @State private var containerPath: [Container.ID] = []

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
                Section("Docker") {
                    ForEach(SidebarItem.allCases.filter { $0 != .engine }) { item in
                        Label(item.rawValue, systemImage: item.systemImage)
                            .badge(badge(for: item))
                            .tag(item)
                    }
                }
                Section("System") {
                    Label(SidebarItem.engine.rawValue, systemImage: SidebarItem.engine.systemImage)
                        .tag(SidebarItem.engine)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                EngineStatusBar().onTapGesture { section = .engine }
            }
        } detail: {
            if section == .engine {
                EngineView()
            } else if engine.isRunning {
                switch section {
                case .containers: ContainersView(path: $containerPath, runRequest: $runPrefill)
                case .images: ImagesView()
                case .volumes: VolumesView()
                case .networks: NetworksView()
                case .builds: BuildsView(path: $buildPath, newBuild: $newBuild)
                case .engine: EmptyView()
                }
            } else {
                EngineUnavailableView()
            }
        }
        .sheet(item: $newBuild) { request in
            NewBuildSheet(request: request) { session in
                section = .builds
                buildPath = [session.id.uuidString]
            }
        }
        .sheet(item: $runPrefill) { prefill in
            RunSheet(prefill: prefill) { id in
                section = .containers
                containerPath = [id]
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .runImage)) { note in
            runPrefill = RunPrefill(image: note.object as? String ?? "")
        }
        .alert("Something went wrong", isPresented: Binding(get: { lastError != nil }, set: { if !$0 { clearErrors() } })) {
            Button("OK") {}
        } message: {
            Text(lastError ?? "")
        }
        .onChange(of: engine.api?.socketPath, initial: true) {
            containers.api = engine.api
            images.api = engine.api
            volumes.api = engine.api
            networks.api = engine.api
            disk.api = engine.api
            Task {
                await containers.refresh()
                await images.refresh()
            }
        }
        .onChange(of: section) {
            if section == .images { Task { await images.refresh() } }
        }
        .onChange(of: builds.runningCount) {
            // A finished build usually produced an image.
            Task { await images.refresh() }
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .containers: containers.runningCount
        case .builds: builds.runningCount
        default: 0
        }
    }

    private var lastError: String? {
        containers.lastError ?? images.lastError ?? volumes.lastError ?? networks.lastError ?? builds.lastError ?? disk.lastError
    }

    private func clearErrors() {
        containers.lastError = nil
        images.lastError = nil
        volumes.lastError = nil
        networks.lastError = nil
        builds.lastError = nil
        disk.lastError = nil
    }
}

extension BuildRequest: Identifiable {
    var id: Self { self }
}

private struct EngineStatusBar: View {
    @Environment(EngineStore.self) private var engine

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: engine.isRunning ? 3 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(engine.statusText).font(.callout.weight(.medium))
                if let info = engine.info {
                    Text("Docker \(info.ServerVersion) · \(info.NCPU) CPU · \(ByteCountFormatter.string(fromByteCount: info.MemTotal, countStyle: .memory))")
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                if engine.isRunning {
                    Button("Stop Engine", action: engine.stop)
                } else {
                    Button("Start Engine", action: engine.start)
                }
                Button("Refresh") { Task { await engine.refresh() } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var color: Color {
        switch engine.state {
        case .running: .green
        case .starting, .stopping, .checking: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }
}

private struct EngineUnavailableView: View {
    @Environment(EngineStore.self) private var engine

    var body: some View {
        switch engine.state {
        case .checking:
            ProgressView()
        case .starting, .stopping:
            ContentUnavailableView {
                ProgressView().controlSize(.large)
            } description: {
                Text(engine.state == .starting ? "Starting Colima…" : "Stopping Colima…").font(.title3)
                if !engine.startLog.isEmpty {
                    Text(engine.startLog).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            }
        case .stopped, .failed, .running:
            ContentUnavailableView {
                Label("Docker Engine Is Stopped", systemImage: "shippingbox")
            } description: {
                if case .failed(let message) = engine.state {
                    Text(message)
                } else {
                    Text("Containers, images and builds live in the Colima virtual machine.")
                }
            } actions: {
                Button("Start Engine", action: engine.start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
