import SwiftUI

struct ContentView: View {
    @Environment(EngineStore.self) private var engine
    @Environment(ImagesStore.self) private var images
    @Environment(BuildsStore.self) private var builds
    @Binding var section: SidebarItem
    @Binding var newBuild: BuildRequest?
    @State private var buildPath: [BuildItem.ID] = []

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .badge(item == .builds && builds.runningCount > 0 ? builds.runningCount : 0)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) { EngineStatusBar() }
        } detail: {
            if engine.isRunning {
                switch section {
                case .images: ImagesView()
                case .builds: BuildsView(path: $buildPath, newBuild: $newBuild)
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
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { images.lastError != nil || builds.lastError != nil },
                set: { if !$0 { images.lastError = nil; builds.lastError = nil } }
            ),
            actions: { Button("OK") {} },
            message: { Text(images.lastError ?? builds.lastError ?? "") }
        )
        .onChange(of: engine.api?.socketPath, initial: true) {
            images.api = engine.api
            Task { await images.refresh() }
        }
        .onChange(of: section) {
            if section == .images { Task { await images.refresh() } }
        }
        .onChange(of: builds.runningCount) {
            // A finished build usually produced an image.
            Task { await images.refresh() }
        }
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
                    Text("Images and builds live in the Colima virtual machine.")
                }
            } actions: {
                Button("Start Engine", action: engine.start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
