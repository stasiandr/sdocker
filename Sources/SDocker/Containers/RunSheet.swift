import AppKit
import SwiftUI

/// Opens the run sheet, optionally for a given image.
struct RunPrefill: Identifiable {
    let id = UUID()
    var image = ""
}

/// Run a container from an image, like `docker run -d`.
struct RunSheet: View {
    @Environment(ContainersStore.self) private var containers
    @Environment(ImagesStore.self) private var images
    @Environment(VolumesStore.self) private var volumes
    @Environment(NetworksStore.self) private var networks
    @Environment(\.dismiss) private var dismiss
    let onStarted: (Container.ID) -> Void

    @State private var image: String
    @State private var name = ""
    @State private var command = ""
    @State private var ports: [PortRow] = []
    @State private var env: [EnvRow] = []
    @State private var mounts: [MountRow] = []
    @State private var network = ""
    @State private var restart = "no"
    @State private var autoRemove = false
    @State private var isStarting = false
    @State private var error: String?

    struct PortRow: Identifiable { let id = UUID(); var host = ""; var container = ""; var proto = "tcp" }
    struct EnvRow: Identifiable { let id = UUID(); var key = ""; var value = "" }
    struct MountRow: Identifiable { let id = UUID(); var source = ""; var target = ""; var readOnly = false }

    init(prefill: RunPrefill, onStarted: @escaping (Container.ID) -> Void) {
        self.onStarted = onStarted
        _image = State(initialValue: prefill.image)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack {
                        TextField("Image", text: $image, prompt: Text("nginx:alpine"))
                        Menu {
                            ForEach(localImages, id: \.self) { ref in Button(ref) { image = ref } }
                        } label: {
                            Image(systemName: "shippingbox")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Local images")
                    }
                    TextField("Name", text: $name, prompt: Text("Random name"))
                    TextField("Command", text: $command, prompt: Text("Image default"))
                        .font(.body.monospaced())
                } footer: {
                    if !image.isEmpty, !localImages.contains(where: { $0 == image || $0 == image + ":latest" }) {
                        Text("Not available locally, it will be pulled first.")
                    }
                }

                Section("Ports") {
                    ForEach($ports) { $port in
                        HStack {
                            TextField("Host", text: $port.host, prompt: Text("8080")).labelsHidden().frame(width: 80)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Container", text: $port.container, prompt: Text("80")).labelsHidden().frame(width: 80)
                            Picker("", selection: $port.proto) {
                                Text("TCP").tag("tcp")
                                Text("UDP").tag("udp")
                            }
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                            RemoveButton { ports.removeAll { $0.id == port.id } }
                        }
                    }
                    Button { ports.append(PortRow()) } label: { Label("Publish Port", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }

                Section("Volumes") {
                    ForEach($mounts) { $mount in
                        HStack {
                            TextField("Source", text: $mount.source, prompt: Text("volume or /host/path")).labelsHidden()
                            Menu {
                                ForEach(volumes.volumes.map(\.name), id: \.self) { v in Button(v) { mount.source = v } }
                                if !volumes.volumes.isEmpty { Divider() }
                                Button("Choose Folder…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = true
                                    if panel.runModal() == .OK, let url = panel.url { mount.source = url.path }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuIndicator(.hidden)
                            .fixedSize()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Target", text: $mount.target, prompt: Text("/data")).labelsHidden()
                            Toggle("RO", isOn: $mount.readOnly).toggleStyle(.checkbox).help("Read-only")
                            RemoveButton { mounts.removeAll { $0.id == mount.id } }
                        }
                    }
                    Button { mounts.append(MountRow()) } label: { Label("Add Volume", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }

                Section("Environment") {
                    ForEach($env) { $item in
                        HStack {
                            TextField("Name", text: $item.key, prompt: Text("NAME")).labelsHidden().font(.body.monospaced())
                            Text("=").foregroundStyle(.secondary)
                            TextField("Value", text: $item.value, prompt: Text("value")).labelsHidden()
                            RemoveButton { env.removeAll { $0.id == item.id } }
                        }
                    }
                    Button { env.append(EnvRow()) } label: { Label("Add Variable", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }

                Section("Options") {
                    Picker("Network", selection: $network) {
                        Text("Default (bridge)").tag("")
                        ForEach(networks.networks.map(\.name).filter { $0 != "bridge" }, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Restart", selection: $restart) {
                        Text("Never").tag("no")
                        Text("On failure").tag("on-failure")
                        Text("Unless stopped").tag("unless-stopped")
                        Text("Always").tag("always")
                    }
                    .disabled(autoRemove)
                    Toggle("Remove when it exits", isOn: $autoRemove)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .font(.callout)
                }
                Spacer()
                if isStarting { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(image.trimmingCharacters(in: .whitespaces).isEmpty || isStarting)
            }
            .padding(16)
        }
        .frame(width: 560, height: 660)
        .task {
            await volumes.refresh()
            await networks.refresh()
        }
    }

    private var localImages: [String] {
        images.rows.filter { !$0.isDangling }.map(\.reference)
    }

    private func run() {
        var request = ContainersStore.RunRequest()
        request.image = image.trimmingCharacters(in: .whitespaces)
        request.name = name
        request.command = command
        request.ports = ports.map { ($0.host, $0.container, $0.proto) }
        request.env = env.map { ($0.key, $0.value) }
        request.volumes = mounts.map { ($0.source, $0.target, $0.readOnly) }
        request.network = network
        request.restart = restart
        request.autoRemove = autoRemove
        isStarting = true
        error = nil
        Task {
            do {
                let id = try await containers.run(request)
                dismiss()
                onStarted(id)
            } catch {
                self.error = error.localizedDescription
            }
            isStarting = false
        }
    }
}

struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}
