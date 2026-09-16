import AppKit
import SwiftUI

struct NewBuildSheet: View {
    @Environment(BuildsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onStarted: (BuildSession) -> Void

    @State private var request: BuildRequest
    @State private var tags: String
    @State private var args: [Arg]
    @State private var amd64: Bool
    @State private var arm64: Bool

    struct Arg: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    init(request: BuildRequest, onStarted: @escaping (BuildSession) -> Void) {
        self.onStarted = onStarted
        _request = State(initialValue: request)
        _tags = State(initialValue: request.tags.joined(separator: ", "))
        _args = State(initialValue: request.buildArgs.sorted { $0.key < $1.key }.map { Arg(key: $0.key, value: $0.value) })
        _amd64 = State(initialValue: request.platforms.contains("linux/amd64"))
        _arm64 = State(initialValue: request.platforms.contains("linux/arm64"))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Context") {
                        HStack {
                            Text(hasContext ? abbreviated(request.context.path) : "None")
                                .foregroundStyle(hasContext ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Button("Choose…", action: chooseContext)
                        }
                    }
                    Picker("Dockerfile", selection: $request.dockerfile) {
                        ForEach(dockerfiles, id: \.self) { Text($0).tag($0) }
                        if dockerfiles.isEmpty { Text("No Dockerfile found").tag("") }
                    }
                    .disabled(dockerfiles.isEmpty)
                    Picker("Target stage", selection: $request.target) {
                        Text("Last stage").tag("")
                        ForEach(stages, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(stages.isEmpty)
                } footer: {
                    if hasContext && dockerfiles.isEmpty {
                        Text("This folder has no Dockerfile.").foregroundStyle(.red)
                    }
                }

                Section("Image") {
                    TextField("Tags", text: $tags, prompt: Text("myapp:latest, myapp:1.0"))
                    LabeledContent("Platforms") {
                        HStack(spacing: 14) {
                            Toggle("linux/arm64", isOn: $arm64)
                            Toggle("linux/amd64", isOn: $amd64)
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Section {
                    ForEach($args) { $arg in
                        HStack {
                            TextField("Name", text: $arg.key, prompt: Text("NAME")).labelsHidden()
                                .font(.body.monospaced())
                            Text("=").foregroundStyle(.secondary)
                            TextField("Value", text: $arg.value, prompt: Text("value")).labelsHidden()
                            Button {
                                args.removeAll { $0.id == arg.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { args.append(Arg()) } label: { Label("Add Build Argument", systemImage: "plus") }
                        .buttonStyle(.borderless)
                } header: {
                    Text("Build arguments")
                } footer: {
                    if !declaredArgs.isEmpty {
                        Text("Declared in Dockerfile: \(declaredArgs.joined(separator: ", "))")
                    }
                }

                Section("Options") {
                    Toggle("Don't use cache", isOn: $request.noCache)
                    Toggle("Always pull base images", isOn: $request.pull)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(verbatim: commandPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Build", action: build)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasContext || dockerfiles.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear {
            if !hasContext { chooseContext() }
            if request.dockerfile.isEmpty || !dockerfiles.contains(request.dockerfile) {
                request.dockerfile = dockerfiles.first ?? ""
            }
        }
    }

    private var hasContext: Bool {
        request.context.path != NSHomeDirectory()
    }

    /// Dockerfiles in the context root: Dockerfile, *.Dockerfile, Dockerfile.*.
    private var dockerfiles: [String] {
        guard hasContext,
              let names = try? FileManager.default.contentsOfDirectory(atPath: request.context.path) else { return [] }
        var found = names
            .filter { $0 == "Dockerfile" || $0.hasPrefix("Dockerfile.") || $0.hasSuffix(".Dockerfile") || $0 == "Containerfile" }
            .sorted { $0 == "Dockerfile" ? true : $1 == "Dockerfile" ? false : $0 < $1 }
        // A file picked explicitly may be named anything.
        if !request.dockerfile.isEmpty, !found.contains(request.dockerfile), names.contains(request.dockerfile) {
            found.insert(request.dockerfile, at: 0)
        }
        return found
    }

    private var dockerfileText: String {
        guard !request.dockerfile.isEmpty else { return "" }
        return (try? String(contentsOf: request.context.appendingPathComponent(request.dockerfile), encoding: .utf8)) ?? ""
    }

    private var stages: [String] {
        dockerfileText.split(separator: "\n").compactMap { line in
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard words.count >= 4, words[0].uppercased() == "FROM",
                  let asIndex = words.firstIndex(where: { $0.uppercased() == "AS" }), asIndex + 1 < words.count
            else { return nil }
            return String(words[asIndex + 1])
        }
    }

    private var declaredArgs: [String] {
        dockerfileText.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("ARG ") else { return nil }
            return trimmed.dropFirst(4).split(separator: "=").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
    }

    private var finalRequest: BuildRequest {
        var r = request
        r.tags = tags.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        r.buildArgs = Dictionary(
            args.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 }
        )
        r.platforms = (arm64 ? ["linux/arm64"] : []) + (amd64 ? ["linux/amd64"] : [])
        return r
    }

    private var commandPreview: String {
        let r = finalRequest
        var parts = ["docker buildx build"]
        if !r.dockerfile.isEmpty, r.dockerfile != "Dockerfile" { parts.append("-f \(r.dockerfile)") }
        parts += r.tags.map { "-t \($0)" }
        parts += r.buildArgs.sorted { $0.key < $1.key }.map { "--build-arg \($0.key)=\($0.value)" }
        if !r.target.isEmpty { parts.append("--target \(r.target)") }
        if !r.platforms.isEmpty { parts.append("--platform \(r.platforms.joined(separator: ","))") }
        if r.noCache { parts.append("--no-cache") }
        if r.pull { parts.append("--pull") }
        parts.append(hasContext ? abbreviated(r.context.path) : ".")
        return parts.joined(separator: " ")
    }

    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a build context folder or a Dockerfile"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            request.context = url
            request.dockerfile = dockerfiles.first ?? ""
        } else {
            request.context = url.deletingLastPathComponent()
            request.dockerfile = url.lastPathComponent
        }
        request.target = ""
        if tags.isEmpty {
            tags = request.context.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-") + ":latest"
        }
    }

    private func build() {
        let session = store.start(finalRequest)
        dismiss()
        onStarted(session)
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}
