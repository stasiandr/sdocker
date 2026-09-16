import SwiftUI

struct ImageDetailView: View {
    @Environment(ImagesStore.self) private var store
    let row: ImageRow
    @State private var tab = Tab.layers

    enum Tab: String, CaseIterable {
        case layers = "Layers"
        case config = "Config"
    }

    var body: some View {
        let inspect = store.inspected[row.imageID]
        let layers = store.layers[row.imageID] ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(inspect)
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch tab {
                case .layers: LayersList(layers: layers)
                case .config: ConfigList(inspect: inspect)
                }
            }
            .padding(16)
        }
        .task(id: row.imageID) { await store.loadDetails(for: row.imageID) }
    }

    private func header(_ inspect: ImageInspect?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.isDangling ? row.shortID : row.repository)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if !row.isDangling { Pill(text: row.tag, systemImage: "tag") }
                if let os = inspect?.Os, let arch = inspect?.Architecture {
                    Pill(text: [os, arch, inspect?.Variant].compactMap { $0 }.joined(separator: "/"), systemImage: "cpu")
                }
                Pill(text: format(bytes: row.size), systemImage: "internaldrive")
            }
            Text(row.imageID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Created \(relative(row.created))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Pill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

/// Dockerfile instructions with their layer sizes, like the image layer view on Docker Hub.
private struct LayersList: View {
    let layers: [ImageLayer]

    var body: some View {
        let largest = max(layers.map(\.Size).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(layer.instruction)
                            .font(.callout.monospaced())
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .help(layer.CreatedBy)
                        if layer.Size > 0 {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(.tint.opacity(0.6))
                                    .frame(width: max(3, geo.size.width * CGFloat(layer.Size) / CGFloat(largest)))
                            }
                            .frame(height: 3)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(layer.Size > 0 ? format(bytes: layer.Size) : "0 B")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(layer.Size > 0 ? .secondary : .tertiary)
                }
                .padding(.vertical, 8)
                if index < layers.count - 1 { Divider() }
            }
        }
        if layers.isEmpty {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

private struct ConfigList: View {
    let inspect: ImageInspect?

    var body: some View {
        if let inspect {
            let config = inspect.Config
            VStack(alignment: .leading, spacing: 14) {
                if let entrypoint = config?.Entrypoint, !entrypoint.isEmpty {
                    Field("Entrypoint", entrypoint.joined(separator: " "))
                }
                if let cmd = config?.Cmd, !cmd.isEmpty {
                    Field("Command", cmd.joined(separator: " "))
                }
                if let dir = config?.WorkingDir, !dir.isEmpty { Field("Working directory", dir) }
                if let user = config?.User, !user.isEmpty { Field("User", user) }
                if let ports = config?.ExposedPorts, !ports.isEmpty {
                    Field("Exposed ports", ports.keys.sorted().joined(separator: ", "))
                }
                if let volumes = config?.Volumes, !volumes.isEmpty {
                    Field("Volumes", volumes.keys.sorted().joined(separator: "\n"))
                }
                if let env = config?.Env, !env.isEmpty { Field("Environment", env.joined(separator: "\n")) }
                if let labels = config?.Labels, !labels.isEmpty {
                    Field("Labels", labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
                }
                if let tags = inspect.RepoTags, !tags.isEmpty { Field("Tags", tags.joined(separator: "\n")) }
                if let digests = inspect.RepoDigests, !digests.isEmpty { Field("Digests", digests.joined(separator: "\n")) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

private struct Field: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
