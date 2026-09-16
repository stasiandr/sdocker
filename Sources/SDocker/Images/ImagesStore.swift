import Foundation
import Observation

@MainActor
@Observable
final class ImagesStore {
    /// A pull in progress, with per-layer byte counts.
    @Observable
    final class Pull: Identifiable {
        let id = UUID()
        let reference: String
        var status = "Starting…"
        var layers: [String: (current: Int64, total: Int64)] = [:]
        var done = false
        var error: String?

        init(reference: String) {
            self.reference = reference
        }

        var fraction: Double? {
            let total = layers.values.reduce(Int64(0)) { $0 + $1.total }
            guard total > 0 else { return nil }
            return Double(layers.values.reduce(Int64(0)) { $0 + min($1.current, $1.total) }) / Double(total)
        }
    }

    private(set) var rows: [ImageRow] = []
    private(set) var isLoading = false
    private(set) var pulls: [Pull] = []
    private(set) var inspected: [String: ImageInspect] = [:]
    private(set) var layers: [String: [ImageLayer]] = [:]
    var lastError: String?

    var api: DockerAPI?

    var totalSize: Int64 {
        var seen = Set<String>()
        return rows.reduce(0) { seen.insert($1.imageID).inserted ? $0 + $1.size : $0 }
    }

    var imageCount: Int { Set(rows.map(\.imageID)).count }

    var danglingSize: Int64 { rows.filter { $0.isDangling && !$0.inUse }.reduce(0) { $0 + $1.size } }

    func refresh() async {
        guard let api else { rows = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            struct Container: Decodable { let ImageID: String }
            async let images: [ImageSummary] = api.get("/images/json?manifests=1")
            async let containers: [Container] = api.get("/containers/json?all=1")
            let used = Set(try await containers.map(\.ImageID))
            rows = try await images
                .flatMap { ImageRow.rows(from: $0, usedImageIDs: used) }
                .sorted { $0.created > $1.created }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadDetails(for imageID: String) async {
        guard let api else { return }
        let escaped = imageID.urlEscaped
        do {
            async let inspect: ImageInspect = api.get("/images/\(escaped)/json")
            async let history: [ImageLayer] = api.get("/images/\(escaped)/history")
            inspected[imageID] = try await inspect
            layers[imageID] = try await history.reversed()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pull(_ input: String) {
        guard let api else { return }
        var reference = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return }
        // Without a tag the API pulls every tag of the repository.
        let name = reference.split(separator: "/").last ?? ""
        if !name.contains(":") && !reference.contains("@") { reference += ":latest" }

        let pull = Pull(reference: reference)
        pulls.append(pull)
        Task {
            do {
                try await api.streamLines("POST", "/images/create?fromImage=\(reference.urlEscaped)") { line in
                    guard let message = try? JSONDecoder().decode(PullMessage.self, from: line) else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { Self.apply(message, to: pull) } }
                }
                pull.done = true
            } catch {
                pull.error = error.localizedDescription
            }
            await refresh()
            if pull.error == nil {
                try? await Task.sleep(for: .seconds(2))
                pulls.removeAll { $0.id == pull.id }
            }
        }
    }

    func dismiss(_ pull: Pull) {
        pulls.removeAll { $0.id == pull.id }
    }

    private static func apply(_ message: PullMessage, to pull: Pull) {
        if let error = message.error {
            pull.error = error
            return
        }
        if let status = message.status { pull.status = status }
        guard let id = message.id, let detail = message.progressDetail else { return }
        switch message.status {
        case "Downloading":
            if let total = detail.total, total > 0 { pull.layers[id] = (detail.current ?? 0, total) }
        case "Download complete", "Pull complete", "Already exists":
            if let layer = pull.layers[id] { pull.layers[id] = (layer.total, layer.total) }
        default:
            break
        }
    }

    func remove(_ rows: [ImageRow], force: Bool = false) async {
        guard let api else { return }
        for row in rows {
            do {
                // Untagging by reference keeps other tags of the same image.
                try await api.send("DELETE", "/images/\(row.reference.urlEscaped)?force=\(force)")
            } catch {
                lastError = error.localizedDescription
            }
        }
        await refresh()
    }

    func tag(_ row: ImageRow, as newReference: String) async {
        guard let api else { return }
        let ref = newReference.trimmingCharacters(in: .whitespaces)
        var repo = ref, tag = "latest"
        if let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") {
            repo = String(ref[..<colon])
            tag = String(ref[ref.index(after: colon)...])
        }
        do {
            try await api.send("POST", "/images/\(row.imageID.urlEscaped)/tag?repo=\(repo.urlEscaped)&tag=\(tag.urlEscaped)")
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Removes dangling images; returns the reclaimed bytes.
    func pruneDangling() async -> Int64 {
        guard let api else { return 0 }
        struct Report: Decodable { let SpaceReclaimed: Int64 }
        do {
            let filters = #"{"dangling":["true"]}"#.urlEscaped
            let data = try await api.send("POST", "/images/prune?filters=\(filters)")
            await refresh()
            return (try? JSONDecoder().decode(Report.self, from: data))?.SpaceReclaimed ?? 0
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }
}
