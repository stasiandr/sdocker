import AppKit
import Foundation
import Observation

struct Volume: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let driver: String
    let mountpoint: String
    let created: Date?
    let labels: [String: String]
    /// -1 when the daemon didn't compute it.
    let size: Int64
    let project: String?

    /// Anonymous volumes are named by a 64-character hex id.
    var isAnonymous: Bool { name.count == 64 && name.allSatisfy(\.isHexDigit) }
}

@MainActor
@Observable
final class VolumesStore {
    private(set) var volumes: [Volume] = []
    /// Volume name → names of the containers mounting it.
    private(set) var usedBy: [String: [String]] = [:]
    private(set) var isLoading = false
    var lastError: String?

    var api: DockerAPI?

    var totalSize: Int64 { volumes.reduce(0) { $0 + max($1.size, 0) } }

    func refresh() async {
        guard let api else { volumes = []; return }
        isLoading = true
        defer { isLoading = false }

        struct VolumeJSON: Decodable {
            let Name: String
            let Driver: String
            let Mountpoint: String
            let CreatedAt: String?
            let Labels: [String: String]?
            let UsageData: Usage?

            struct Usage: Decodable { let Size: Int64 }
        }
        struct DF: Decodable { let Volumes: [VolumeJSON]? }

        do {
            // `system/df` includes sizes; it lists the same volumes as `/volumes`.
            async let df: DF = api.get("/system/df?type=volume")
            async let list: [ContainerSummary] = api.get("/containers/json?all=1")
            var users: [String: [String]] = [:]
            for c in try await list.map(Container.init) {
                for mount in c.mounts where mount.Type == "volume" {
                    if let name = mount.Name { users[name, default: []].append(c.name) }
                }
            }
            usedBy = users
            volumes = (try await df.Volumes ?? []).map {
                Volume(
                    name: $0.Name, driver: $0.Driver, mountpoint: $0.Mountpoint,
                    created: ISO8601DateFormatter.parse($0.CreatedAt), labels: $0.Labels ?? [:],
                    size: $0.UsageData?.Size ?? -1, project: $0.Labels?["com.docker.compose.project"]
                )
            }
            .sorted { ($0.isAnonymous ? 1 : 0, $0.name) < ($1.isAnonymous ? 1 : 0, $1.name) }
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }

    func create(name: String) async {
        guard let api else { return }
        do {
            try await api.send("POST", "/volumes/create", json: ["Name": name.trimmingCharacters(in: .whitespaces)])
        } catch {
            lastError = message(for: error) ?? lastError
        }
        await refresh()
    }

    func remove(_ names: [String]) async {
        guard let api else { return }
        for name in names {
            do {
                try await api.send("DELETE", "/volumes/\(name.urlEscaped)")
            } catch {
                lastError = message(for: error) ?? lastError
            }
        }
        await refresh()
    }

    /// Removes every volume no container uses, named ones included; returns the reclaimed bytes.
    func pruneUnused() async -> Int64 {
        guard let api else { return 0 }
        struct Report: Decodable { let SpaceReclaimed: Int64 }
        do {
            let filters = #"{"all":["true"]}"#.urlEscaped
            let data = try await api.send("POST", "/volumes/prune?filters=\(filters)")
            await refresh()
            return (try? JSONDecoder().decode(Report.self, from: data))?.SpaceReclaimed ?? 0
        } catch {
            lastError = message(for: error) ?? lastError
            return 0
        }
    }

    // MARK: - Files

    /// Image of the throwaway helper container that reads volumes.
    private static let helperImage = "alpine:3.20"

    /// Lists a folder of a volume through a short-lived read-only helper container.
    func listFiles(_ volume: String, path: String) async throws -> [FileEntry] {
        let output: Data
        do {
            output = try await Shell.run("docker", [
                "run", "--rm", "--network", "none", "-v", "\(volume):/volume:ro", Self.helperImage,
                "sh", "-c", FileEntry.listScript, "sh", path,
            ])
        } catch let error as ShellError where error.status == 2 {
            throw DockerAPIError(status: 0, message: "Can't open \(path)")
        }
        return FileEntry.parse(String(decoding: output, as: UTF8.self), in: path)
    }

    /// Copies a file or folder out of a volume via a created (never started) helper container.
    func download(_ volume: String, path: String) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let created = try await Shell.run("docker", ["create", "-v", "\(volume):/volume:ro", Self.helperImage])
            let id = String(decoding: created, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            defer { Task { _ = try? await Shell.run("docker", ["rm", id]) } }
            _ = try await Shell.run("docker", ["cp", "\(id):\(path)", url.path])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }
}
