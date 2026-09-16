import AppKit
import Charts
import SwiftUI

struct ContainerDetailView: View {
    @Environment(ContainersStore.self) private var store
    @Environment(EngineStore.self) private var engine
    let containerID: Container.ID
    /// `-tab stats` picks the first tab, for scripted screenshots.
    @State private var tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab")?.capitalized ?? "") ?? .logs
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable {
        case logs = "Logs"
        case stats = "Stats"
        case exec = "Exec"
        case files = "Files"
        case inspect = "Inspect"
    }

    var body: some View {
        if let container = store.container(containerID) {
            content(container)
        } else {
            ContentUnavailableView("Container Removed", systemImage: "square.stack.3d.up.slash")
        }
    }

    private func content(_ c: Container) -> some View {
        VStack(spacing: 0) {
            header(c)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)
            Divider()

            Group {
                switch tab {
                case .logs: LogsTab(container: c)
                case .stats: StatsTab(container: c)
                case .exec: ExecTab(container: c)
                case .files:
                    if c.state == .running {
                        FileBrowser(list: { try await store.listFiles(c.id, path: $0) },
                                    download: { entry in Task { await store.download(c.id, path: entry.path) } })
                    } else {
                        ContentUnavailableView("Container Is Not Running", systemImage: "folder",
                                               description: Text("Start the container to browse its files."))
                    }
                case .inspect: InspectTab(container: c)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(c.name)
        .toolbar {
            ToolbarItemGroup {
                if store.busy.contains(c.id) {
                    ProgressView().controlSize(.small)
                }
                if c.state.isActive {
                    Button { Task { await store.perform(.stop, on: [c.id]) } } label: { Label("Stop", systemImage: "stop.fill") }
                    Button { Task { await store.perform(.restart, on: [c.id]) } } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button { Task { await store.perform(.start, on: [c.id]) } } label: { Label("Start", systemImage: "play.fill") }
                }
                if c.state == .running {
                    Button { Task { await store.perform(.pause, on: [c.id]) } } label: { Label("Pause", systemImage: "pause.fill") }
                } else if c.state == .paused {
                    Button { Task { await store.perform(.unpause, on: [c.id]) } } label: {
                        Label("Resume", systemImage: "playpause.fill")
                    }
                }
                Button { store.openTerminal(c) } label: { Label("Terminal", systemImage: "apple.terminal") }
                    .disabled(c.state != .running)
                    .help("Open a shell in Ghostty")
                Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .confirmationDialog("Delete \(c.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.remove([c.id])
                    dismiss()
                }
            }
        }
        .task(id: c.state) { await store.loadInspect(c.id) }
    }

    private func header(_ c: Container) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(stateColor(c.state).gradient, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(c.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(c.state.rawValue.capitalized)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(stateColor(c.state).opacity(0.18), in: Capsule())
                        .foregroundStyle(stateColor(c.state))
                }
                HStack(spacing: 14) {
                    Label(c.image, systemImage: "shippingbox").lineLimit(1)
                    Label(c.status, systemImage: "clock")
                    Text(c.shortID).font(.callout.monospaced()).textSelection(.enabled)
                    if !c.ports.isEmpty {
                        PortLinks(ports: c.ports, active: c.state == .running)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func stateColor(_ state: Container.State) -> Color {
        switch state {
        case .running: .green
        case .paused: .yellow
        case .restarting: .orange
        case .dead: .red
        default: .gray
        }
    }
}

// MARK: - Logs

private struct LogsTab: View {
    @Environment(EngineStore.self) private var engine
    @Environment(ContainersStore.self) private var store
    let container: Container
    @State private var session = LogSession()
    @State private var filter = ""
    @State private var showTimestamps = false
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Filter", text: $filter, prompt: Text("Filter lines"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Toggle("Timestamps", isOn: $showTimestamps)
                Toggle("Follow", isOn: $follow)
                Spacer()
                if session.isFollowing {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                }
                Text("\(visible.count) lines").foregroundStyle(.secondary).monospacedDigit()
                Button { copyAll() } label: { Image(systemName: "doc.on.doc") }.help("Copy visible lines")
                Button { session.clear() } label: { Image(systemName: "clear") }.help("Clear")
            }
            .toggleStyle(.checkbox)
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visible) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if showTimestamps, let ts = line.timestamp {
                                    Text(shortTimestamp(ts)).foregroundStyle(.tertiary)
                                }
                                Text(line.text.isEmpty ? " " : line.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // stderr lines get a thin red marker instead of red text: many tools log there normally.
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                if line.isError { Rectangle().fill(.red.opacity(0.7)).frame(width: 2) }
                            }
                            .id(line.id)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: session.lines.last?.id) {
                    if follow, let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .overlay {
                    if let error = session.error {
                        ContentUnavailableView("Can't Read Logs", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else if session.lines.isEmpty {
                        Text("No output yet").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: container.state) {
            guard let api = engine.api else { return }
            if store.inspected[container.id] == nil { await store.loadInspect(container.id) }
            session.start(api: api, id: container.id, tty: store.inspected[container.id]?.Config.Tty ?? false)
        }
        .onDisappear { session.stop() }
    }

    private var visible: [LogLine] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? session.lines : session.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private func shortTimestamp(_ ts: String) -> String {
        guard let date = ISO8601DateFormatter.parse(ts) else { return ts }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visible.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Stats

private struct StatsTab: View {
    @Environment(EngineStore.self) private var engine
    let container: Container
    @State private var session = StatsSession()

    var body: some View {
        Group {
            if container.state != .running {
                ContentUnavailableView("Container Is Not Running", systemImage: "chart.xyaxis.line",
                                       description: Text("Stats are collected while the container runs."))
            } else if session.samples.isEmpty {
                ProgressView("Collecting stats…")
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            ChartCard(title: "CPU", value: percent(session.latest?.cpuPercent ?? 0),
                                      samples: session.samples, metric: \.cpuPercent, color: .blue, unit: "%")
                            ChartCard(
                                title: "Memory",
                                value: "\(format(bytes: session.latest?.memoryUsed ?? 0)) of \(format(bytes: session.latest?.memoryLimit ?? 0))",
                                samples: session.samples, metric: { Double($0.memoryUsed) / 1_048_576 }, color: .purple, unit: "MB"
                            )
                        }
                        HStack(alignment: .top, spacing: 16) {
                            NumberCard(title: "Network", rows: [
                                ("Received", format(bytes: session.latest?.netRx ?? 0)),
                                ("Sent", format(bytes: session.latest?.netTx ?? 0)),
                            ])
                            NumberCard(title: "Disk I/O", rows: [
                                ("Read", format(bytes: session.latest?.blockRead ?? 0)),
                                ("Written", format(bytes: session.latest?.blockWrite ?? 0)),
                            ])
                            NumberCard(title: "Processes", rows: [("PIDs", "\(session.latest?.pids ?? 0)")])
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task(id: container.state) {
            guard container.state == .running, let api = engine.api else { return }
            session.start(api: api, id: container.id)
        }
        .onDisappear { session.stop() }
    }
}

private struct ChartCard: View {
    let title: String
    let value: String
    let samples: [StatsSample]
    let metric: (StatsSample) -> Double
    let color: Color
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Chart(samples) { sample in
                AreaMark(x: .value("Time", sample.date), y: .value(unit, metric(sample)))
                    .foregroundStyle(color.opacity(0.18).gradient)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", sample.date), y: .value(unit, metric(sample)))
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .frame(height: 140)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct NumberCard: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                    Spacer()
                    Text(row.1).fontWeight(.medium).monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Exec

private struct ExecTab: View {
    @Environment(ContainersStore.self) private var store
    let container: Container
    @State private var command = ""
    @State private var transcript: [(id: Int, command: String, output: String, exitCode: Int?)] = []
    @State private var isRunning = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if transcript.isEmpty {
                            Text("Run a command inside \(container.name). For an interactive shell, use Terminal in the toolbar.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                        ForEach(transcript, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text("$").foregroundStyle(.green)
                                    Text(entry.command).fontWeight(.semibold)
                                    if let code = entry.exitCode, code != 0 {
                                        Text("exit \(code)").foregroundStyle(.red).font(.caption)
                                    }
                                }
                                if !entry.output.isEmpty {
                                    Text(strippingANSI(entry.output.trimmingCharacters(in: .newlines)))
                                        .textSelection(.enabled)
                                }
                            }
                            .id(entry.id)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: transcript.count) {
                    if let last = transcript.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Text("$").font(.body.monospaced()).foregroundStyle(.secondary)
                TextField("Command", text: $command, prompt: Text("ls -la /"))
                    .textFieldStyle(.plain)
                    .font(.body.monospaced())
                    .focused($focused)
                    .onSubmit(run)
                    .disabled(container.state != .running)
                if isRunning { ProgressView().controlSize(.small) }
            }
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func run() {
        let line = command.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !isRunning else { return }
        command = ""
        isRunning = true
        let id = transcript.count
        Task {
            do {
                let result = try await store.exec(container.id, ["sh", "-c", line])
                transcript.append((id, line, result.output, result.exitCode))
            } catch {
                transcript.append((id, line, error.localizedDescription, -1))
            }
            isRunning = false
            focused = true
        }
    }
}

// MARK: - Inspect

private struct InspectTab: View {
    @Environment(ContainersStore.self) private var store
    let container: Container

    var body: some View {
        if let info = store.inspected[container.id] {
            ScrollView {
                Form {
                    Section("Container") {
                        row("ID", info.Id)
                        row("Image", container.image)
                        row("Command", ((info.Config.Entrypoint ?? []) + (info.Config.Cmd ?? [])).joined(separator: " "))
                        row("Working directory", info.Config.WorkingDir)
                        row("User", info.Config.User)
                        row("Restart policy", info.HostConfig?.RestartPolicy?.Name)
                        row("Created", ISO8601DateFormatter.parse(info.Created)?.formatted())
                        row("Started", ISO8601DateFormatter.parse(info.State.StartedAt)?.formatted())
                        if !container.state.isActive {
                            row("Exit code", info.State.ExitCode.map(String.init))
                            row("Finished", ISO8601DateFormatter.parse(info.State.FinishedAt)?.formatted())
                        }
                        row("Health", info.State.Health?.Status)
                        if info.State.OOMKilled == true { row("OOM killed", "Yes") }
                        row("Error", info.State.Error)
                    }
                    if !container.ports.isEmpty || !container.exposedOnly.isEmpty {
                        Section("Ports") {
                            ForEach(container.ports, id: \.self) { p in
                                LabeledContent(String(p.PrivatePort) + "/" + p.Type) { Text("localhost:" + String(p.PublicPort!)) }
                            }
                            ForEach(container.exposedOnly, id: \.self) { p in
                                LabeledContent(String(p)) { Text("not published").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if let mounts = info.Mounts, !mounts.isEmpty {
                        Section("Mounts") {
                            ForEach(mounts, id: \.self) { m in
                                LabeledContent(m.Destination) {
                                    HStack(spacing: 6) {
                                        Text(m.Name ?? m.Source ?? "").textSelection(.enabled)
                                        Text(m.Type).font(.caption).foregroundStyle(.secondary)
                                        if m.RW == false { Text("read-only").font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }
                        }
                    }
                    if !container.networks.isEmpty {
                        Section("Networks") {
                            ForEach(container.networks.sorted { $0.key < $1.key }, id: \.key) { name, ip in
                                LabeledContent(name) { Text(ip.isEmpty ? "—" : ip).font(.body.monospaced()).textSelection(.enabled) }
                            }
                        }
                    }
                    if let env = info.Config.Env, !env.isEmpty {
                        Section("Environment") {
                            ForEach(env, id: \.self) { item in
                                let parts = item.split(separator: "=", maxSplits: 1)
                                LabeledContent(String(parts[0])) {
                                    Text(parts.count > 1 ? String(parts[1]) : "")
                                        .font(.body.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                }
                            }
                        }
                    }
                    if let labels = info.Config.Labels, !labels.isEmpty {
                        Section("Labels") {
                            ForEach(labels.sorted { $0.key < $1.key }, id: \.key) { key, value in
                                LabeledContent(key) { Text(value).textSelection(.enabled).lineLimit(3) }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing).lineLimit(4)
            }
        }
    }
}
