import SwiftUI

/// Colima resources and Docker disk usage, like Docker Desktop's Resources settings.
struct EngineView: View {
    @Environment(EngineStore.self) private var engine
    @Environment(DiskStore.self) private var disk
    @State private var cpus = 2
    @State private var memoryGiB = 2
    @State private var diskGiB = 100
    @State private var confirmApply = false
    @State private var cleaning: DiskStore.Category.Kind?
    @State private var message: String?

    private let hostCPUs = ProcessInfo.processInfo.activeProcessorCount
    private let hostMemoryGiB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(statusColor.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engine.statusText).font(.title3.weight(.semibold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    switch engine.state {
                    case .running: Button("Stop", action: engine.stop)
                    case .starting, .stopping, .checking: ProgressView().controlSize(.small)
                    case .stopped, .failed: Button("Start", action: engine.start).buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("CPUs") {
                    Stepper("\(cpus)", value: $cpus, in: 1...hostCPUs).monospacedDigit()
                }
                LabeledContent("Memory") {
                    HStack {
                        Slider(value: Binding(get: { Double(memoryGiB) }, set: { memoryGiB = Int($0) }),
                               in: 1...Double(max(hostMemoryGiB, 2)), step: 1)
                            .frame(width: 220)
                        Text("\(memoryGiB) GB").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Disk") {
                    Stepper("\(diskGiB) GB", value: $diskGiB, in: (engine.vm?.diskGiB ?? 20)...2048, step: 10)
                        .monospacedDigit()
                }
                if let vm = engine.vm {
                    LabeledContent("Virtualization", value: [vm.vmType, vm.mountType, vm.arch].filter { !$0.isEmpty }.joined(separator: " · "))
                }
            } header: {
                Text("Resources")
            } footer: {
                HStack(alignment: .top) {
                    Text("Applying restarts the VM and stops running containers. The disk can only grow.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply & Restart…") { confirmApply = true }
                        .disabled(!hasChanges || engine.state == .starting || engine.state == .stopping)
                }
            }

            Section {
                if disk.categories.isEmpty {
                    Text(engine.isRunning ? "Loading…" : "Start the engine to see disk usage.").foregroundStyle(.secondary)
                } else {
                    usageBar
                        .padding(.vertical, 6)
                    ForEach(disk.categories) { category in
                        categoryRow(category)
                    }
                }
            } header: {
                HStack {
                    Text("Disk usage")
                    Spacer()
                    if disk.isLoading { ProgressView().controlSize(.mini) }
                    Button { Task { await disk.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(!engine.isRunning)
                }
            } footer: {
                if let vm = disk.vmDisk {
                    Text("VM disk: \(format(bytes: vm.used)) used of \(format(bytes: vm.size)), \(format(bytes: vm.available)) free.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .navigationTitle("Engine")
        .onAppear(perform: loadVM)
        .onChange(of: engine.vm) { loadVM() }
        .task(id: engine.isRunning) { await disk.refresh() }
        .confirmationDialog("Restart the engine with new resources?", isPresented: $confirmApply) {
            Button("Apply & Restart") { engine.apply(cpus: cpus, memoryGiB: memoryGiB, diskGiB: diskGiB) }
        } message: {
            Text("\(cpus) CPUs, \(memoryGiB) GB memory, \(diskGiB) GB disk. Running containers will be stopped.")
        }
        .confirmationDialog(cleanTitle, isPresented: Binding(get: { cleaning != nil }, set: { if !$0 { cleaning = nil } })) {
            if let kind = cleaning {
                Button("Clean Up", role: .destructive) {
                    Task { message = "Reclaimed \(format(bytes: await disk.clean(kind)))." }
                }
            }
        } message: {
            Text(cleanMessage)
        }
        .alert("Disk Usage", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        } message: {
            Text(message ?? "")
        }
    }

    private var subtitle: String {
        if case .failed(let error) = engine.state { return error }
        if engine.state == .starting, !engine.startLog.isEmpty { return engine.startLog }
        guard let info = engine.info else { return "Colima virtual machine" }
        return "Docker \(info.ServerVersion) · \(info.NCPU) CPUs · \(ByteCountFormatter.string(fromByteCount: info.MemTotal, countStyle: .memory)) · \(info.Driver)"
    }

    private var statusColor: Color {
        switch engine.state {
        case .running: .green
        case .failed: .red
        case .stopped: .gray
        default: .orange
        }
    }

    private var hasChanges: Bool {
        guard let vm = engine.vm else { return false }
        return vm.cpus != cpus || vm.memoryGiB != memoryGiB || vm.diskGiB != diskGiB
    }

    private func loadVM() {
        guard let vm = engine.vm else { return }
        cpus = vm.cpus
        memoryGiB = vm.memoryGiB
        diskGiB = vm.diskGiB
    }

    private static let colors: [DiskStore.Category.Kind: Color] = [
        .images: .blue, .containers: .green, .volumes: .purple, .buildCache: .orange,
    ]

    private var usageBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(format(bytes: disk.dockerTotal)).font(.title2.weight(.semibold)).monospacedDigit()
                Text("used by Docker").foregroundStyle(.secondary)
                Spacer()
                Text("\(format(bytes: disk.reclaimableTotal)) reclaimable").foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let capacity = Double(max(disk.dockerTotal, 1))
                HStack(spacing: 2) {
                    ForEach(disk.categories.filter { $0.total > 0 }) { category in
                        Rectangle()
                            .fill(Self.colors[category.kind, default: .gray].gradient)
                            .frame(width: max(3, geo.size.width * Double(category.total) / capacity))
                    }
                    Spacer(minLength: 0)
                }
                .background(.quaternary)
                .clipShape(Capsule())
            }
            .frame(height: 12)
        }
    }

    private func categoryRow(_ category: DiskStore.Category) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Self.colors[category.kind, default: .gray]).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.kind.rawValue)
                Text(detail(category)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(format(bytes: category.total)).monospacedDigit()
                if category.reclaimable > 0 {
                    Text("\(format(bytes: category.reclaimable)) reclaimable").font(.caption).foregroundStyle(.secondary)
                }
            }
            if disk.cleaning.contains(category.kind) {
                ProgressView().controlSize(.small).frame(width: 96)
            } else {
                Button("Clean Up") { cleaning = category.kind }
                    .disabled(category.reclaimable == 0 && category.kind != .buildCache || category.total == 0)
                    .fixedSize()
                    .frame(width: 96, alignment: .trailing)
            }
        }
    }

    private func detail(_ c: DiskStore.Category) -> String {
        switch c.kind {
        case .images: "\(c.count) images, \(c.active) in use"
        case .containers: "\(c.count) containers, \(c.active) running"
        case .volumes: "\(c.count) volumes, \(c.active) in use"
        case .buildCache: "\(c.count) cache records"
        }
    }

    private var cleanTitle: String {
        switch cleaning {
        case .images: "Remove unused images?"
        case .containers: "Remove stopped containers?"
        case .volumes: "Remove unused volumes?"
        case .buildCache: "Clear the build cache?"
        case nil: ""
        }
    }

    private var cleanMessage: String {
        switch cleaning {
        case .images: "Images that no container uses are deleted, tagged ones included."
        case .containers: "All stopped containers are deleted."
        case .volumes: "Volumes that no container uses are deleted with their data."
        case .buildCache: "The next builds will run without cache."
        case nil: ""
        }
    }
}
