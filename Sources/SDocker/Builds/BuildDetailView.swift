import AppKit
import SwiftUI

struct BuildDetailView: View {
    @Environment(BuildsStore.self) private var store
    let itemID: BuildItem.ID
    let onRebuild: (BuildRequest) -> Void
    @State private var tab = Tab.steps

    enum Tab: String, CaseIterable {
        case steps = "Steps"
        case logs = "Logs"
        case info = "Info"
    }

    var body: some View {
        if let item = store.items.first(where: { $0.id == itemID }) {
            content(item)
        } else {
            ContentUnavailableView("Build Not Found", systemImage: "hammer",
                                   description: Text("It was removed from the build history."))
        }
    }

    private func content(_ item: BuildItem) -> some View {
        let session = store.session(item.sessionID)
        let details = item.ref.flatMap { store.details[$0] }
        let progress = session?.progress ?? item.ref.flatMap { store.recordProgress[$0] }

        return VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                header(item, session: session, progress: progress)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if item.status == .failed {
                ErrorBanner(details: details, progress: progress, messages: session?.messages ?? [])
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 10)

            Divider()

            Group {
                if let progress {
                    switch tab {
                    case .steps: StepsList(progress: progress, isRunning: item.status == .running)
                    case .logs: LogView(progress: progress, isRunning: item.status == .running)
                    case .info: InfoView(request: session?.request, details: details)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItemGroup {
                if let session, session.status == .running {
                    Button { store.cancel(session) } label: { Label("Cancel", systemImage: "stop.fill") }
                }
                if let request = session?.request ?? details.flatMap(Self.request(from:)) {
                    Button { onRebuild(request) } label: { Label("Build Again", systemImage: "arrow.clockwise") }
                        .disabled(item.status == .running)
                }
                if let progress {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(progress.plainLog, forType: .string)
                    } label: {
                        Label("Copy Logs", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .task(id: item.ref) {
            if session == nil || session?.status != .running, let ref = item.ref, store.details[ref] == nil {
                await store.loadDetails(ref: ref)
            }
        }
    }

    private func header(_ item: BuildItem, session: BuildSession?, progress: BuildProgress?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            StatusIcon(status: item.status).font(.largeTitle).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.title2.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 14) {
                    Label(item.status.title, systemImage: "circle.fill")
                        .labelStyle(DotLabelStyle(color: item.status == .completed ? .green : item.status.color))
                    if let started = item.started {
                        Label(started.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    }
                    if let duration = session.map({ ($0.finishedAt ?? .now).timeIntervalSince($0.startedAt) }) ?? item.duration {
                        Label(format(duration: duration), systemImage: "timer")
                    }
                    let steps = progress?.steps.count ?? item.totalSteps
                    let cached = progress?.cachedCount ?? item.cachedSteps
                    Label(cached > 0 ? "\(steps) steps, \(cached) cached" : "\(steps) steps", systemImage: "square.stack.3d.up")
                    if let ref = item.ref {
                        Text(ref).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Reconstructs a build request from a history record, when its context is a local folder.
    private static func request(from details: BuildInspect) -> BuildRequest? {
        guard let context = details.Context, context.hasPrefix("/"),
              FileManager.default.fileExists(atPath: context) else { return nil }
        var request = BuildRequest(context: URL(fileURLWithPath: context))
        request.dockerfile = details.Dockerfile ?? ""
        request.target = details.Target ?? ""
        request.platforms = details.Platform ?? []
        request.tags = details.Tags ?? []
        request.buildArgs = Dictionary((details.BuildArgs ?? []).map { ($0.Name, $0.Value) }, uniquingKeysWith: { $1 })
        return request
    }
}

private struct DotLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title
        }
    }
}

private struct ErrorBanner: View {
    let details: BuildInspect?
    let progress: BuildProgress?
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let step = details?.Error?.Name ?? progress?.failedStep?.name {
                        Text(step).fontWeight(.semibold)
                    }
                    Text(message).textSelection(.enabled)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let sources = details?.Error?.sources, !sources.isEmpty {
                Text(sources.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.red.opacity(0.25)))
    }

    private var message: String {
        details?.Error?.Message
            ?? progress?.failedStep?.error
            ?? messages.last(where: { $0.hasPrefix("ERROR") })
            ?? messages.last
            ?? "The build failed."
    }
}

private struct StepsList: View {
    let progress: BuildProgress
    let isRunning: Bool
    @State private var expanded: Set<BuildStep.ID> = []
    @State private var showInternal = false

    var body: some View {
        let steps = progress.steps
            .filter { showInternal || !$0.isInternal }
            .sorted { ($0.started ?? .distantFuture) < ($1.started ?? .distantFuture) }
        TimelineView(.periodic(from: .now, by: isRunning ? 0.5 : 3600)) { _ in
            List {
                ForEach(steps) { step in
                    StepRow(step: step, isExpanded: binding(for: step))
                }
            }
            .listStyle(.inset)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("Show internal steps", isOn: $showInternal).toggleStyle(.checkbox)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onChange(of: progress.failedStep?.id, initial: true) { _, failed in
            if let failed { expanded.insert(failed) }
        }
    }

    private func binding(for step: BuildStep) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(step.id) },
            set: { if $0 { expanded.insert(step.id) } else { expanded.remove(step.id) } }
        )
    }
}

private struct StepRow: View {
    let step: BuildStep
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(step.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                ForEach(step.tasks, id: \.id) { task in
                    HStack {
                        Text(task.id).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let total = task.total, total > 0 {
                            Text("\(format(bytes: task.current)) / \(format(bytes: total))")
                        } else if task.current > 0 {
                            Text(format(bytes: task.current))
                        }
                        if task.done { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if !step.log.isEmpty {
                    Text(step.log.trimmingCharacters(in: .newlines))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = step.error {
                    Text(error).font(.callout.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                }
                if step.log.isEmpty && step.tasks.isEmpty && step.error == nil && step.warnings.isEmpty {
                    Text("No output").font(.callout).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                icon.frame(width: 16)
                Text(step.name)
                    .font(.callout.monospaced())
                    .foregroundStyle(step.isInternal ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(step.name)
                if step.cached {
                    Text("CACHED")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
                Spacer()
                if let duration = step.duration, !step.cached {
                    Text(String(format: "%.1fs", duration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private var icon: some View {
        if step.error != nil {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if step.isRunning {
            ProgressView().controlSize(.mini)
        } else if step.cached {
            Image(systemName: "bolt.circle.fill").foregroundStyle(.blue)
        } else if step.completed != nil {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        }
    }
}

private struct LogView: View {
    let progress: BuildProgress
    let isRunning: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: isRunning ? 0.5 : 3600)) { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    Text(progress.plainLog)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: progress.plainLog.count) {
                    if isRunning { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }
}

private struct InfoView: View {
    let request: BuildRequest?
    let details: BuildInspect?

    var body: some View {
        ScrollView {
            Form {
                Section("Source") {
                    row("Context", request?.context.path ?? details?.Context)
                    row("Dockerfile", dockerfilePath.map { $0.path } ?? details?.Dockerfile)
                    row("Target", nonEmpty(request?.target) ?? details?.Target)
                    row("Platforms", joined(request?.platforms) ?? joined(details?.Platform))
                }
                Section("Output") {
                    row("Tags", joined(request?.tags) ?? joined(details?.Tags))
                    if let args = buildArgs, !args.isEmpty {
                        ForEach(args, id: \.0) { arg in
                            LabeledContent(arg.0) { Text(arg.1).font(.body.monospaced()).textSelection(.enabled) }
                        }
                    }
                }
                if let materials = details?.Materials, !materials.isEmpty {
                    Section("Base images") {
                        ForEach(materials, id: \.URI) { Text($0.URI).font(.callout.monospaced()).textSelection(.enabled) }
                    }
                }
                if let dockerfile = dockerfileText {
                    Section("Dockerfile") {
                        Text(dockerfile)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) { Text(value).textSelection(.enabled).multilineTextAlignment(.trailing) }
        }
    }

    private var buildArgs: [(String, String)]? {
        if let request { return request.buildArgs.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
        return details?.BuildArgs?.map { ($0.Name, $0.Value) }
    }

    private var dockerfilePath: URL? {
        let contextPath = request?.context.path ?? details?.Context
        guard let contextPath, contextPath.hasPrefix("/") else { return nil }
        let name = nonEmpty(request?.dockerfile) ?? nonEmpty(details?.Dockerfile) ?? "Dockerfile"
        return name.hasPrefix("/") ? URL(fileURLWithPath: name) : URL(fileURLWithPath: contextPath).appendingPathComponent(name)
    }

    private var dockerfileText: String? {
        dockerfilePath.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
    private func joined(_ a: [String]?) -> String? { a?.isEmpty == false ? a!.joined(separator: ", ") : nil }
}
