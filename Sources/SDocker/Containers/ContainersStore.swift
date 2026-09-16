import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ContainersStore {
    private(set) var containers: [Container] = []
    private(set) var stats: [Container.ID: StatsSample] = [:]
    private(set) var isLoading = false
    private(set) var inspected: [Container.ID: ContainerInspect] = [:]
    /// Containers with an action in flight, to show a spinner instead of the buttons.
    private(set) var busy: Set<Container.ID> = []
    var lastError: String?

    var api: DockerAPI?

    var runningCount: Int { containers.filter { $0.state == .running }.count }
    var totalCPU: Double { stats.values.reduce(0) { $0 + $1.cpuPercent } }
    var totalMemory: Int64 { stats.values.reduce(0) { $0 + $1.memoryUsed } }

    func container(_ id: Container.ID) -> Container? {
        containers.first { $0.id == id }
    }

    func refresh() async {
        guard let api else { containers = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            let list: [ContainerSummary] = try await api.get("/containers/json?all=1")
            containers = list.map(Container.init).sorted { $0.created > $1.created }
            let running = Set(containers.filter { $0.state == .running }.map(\.id))
            stats = stats.filter { running.contains($0.key) }
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }

    /// One CPU/memory reading per running container; `stream=false` waits for a second sample itself.
    func refreshStats() async {
        guard let api else { return }
        await withTaskGroup(of: (String, StatsSample?).self) { group in
            for container in containers where container.state == .running {
                group.addTask {
                    let response: StatsResponse? = try? await api.get("/containers/\(container.id)/stats?stream=false")
                    return (container.id, response.flatMap { StatsSample($0) })
                }
            }
            for await (id, sample) in group {
                if let sample { stats[id] = sample }
            }
        }
    }

    func loadInspect(_ id: Container.ID) async {
        guard let api else { return }
        do {
            inspected[id] = try await api.get("/containers/\(id)/json")
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }

    // MARK: - Actions

    enum Action: String {
        case start, stop, restart, pause, unpause, kill
    }

    func perform(_ action: Action, on ids: [Container.ID]) async {
        guard let api else { return }
        await withTaskGroup(of: String?.self) { group in
            for id in ids {
                busy.insert(id)
                group.addTask {
                    do {
                        try await api.send("POST", "/containers/\(id)/\(action.rawValue)")
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
            }
            for await error in group {
                if let error { lastError = error }
            }
        }
        ids.forEach { busy.remove($0) }
        await refresh()
        ids.forEach { inspected[$0] = nil }
    }

    func remove(_ ids: [Container.ID], volumes: Bool = false) async {
        guard let api else { return }
        for id in ids {
            busy.insert(id)
            do {
                try await api.send("DELETE", "/containers/\(id)?force=true&v=\(volumes)")
            } catch {
                lastError = message(for: error) ?? lastError
            }
            busy.remove(id)
        }
        await refresh()
    }

    /// Removes stopped containers; returns the reclaimed bytes.
    func pruneStopped() async -> Int64 {
        guard let api else { return 0 }
        struct Report: Decodable { let SpaceReclaimed: Int64 }
        do {
            let data = try await api.send("POST", "/containers/prune")
            await refresh()
            return (try? JSONDecoder().decode(Report.self, from: data))?.SpaceReclaimed ?? 0
        } catch {
            lastError = message(for: error) ?? lastError
            return 0
        }
    }

    // MARK: - Run

    struct RunRequest {
        var image = ""
        var name = ""
        var command = ""
        var ports: [(host: String, container: String, proto: String)] = []
        var env: [(key: String, value: String)] = []
        var volumes: [(source: String, target: String, readOnly: Bool)] = []
        var network = ""
        var restart = "no"
        var autoRemove = false
    }

    /// Creates and starts a container, pulling the image first when it isn't local.
    func run(_ request: RunRequest) async throws -> Container.ID {
        guard let api else { throw DockerAPIError(status: 0, message: "Docker engine is not running") }

        struct Body: Encodable {
            let Image: String
            let Cmd: [String]?
            let Env: [String]
            let ExposedPorts: [String: [String: String]]
            let HostConfig: Host

            struct Host: Encodable {
                let PortBindings: [String: [[String: String]]]
                let Binds: [String]
                let RestartPolicy: [String: String]
                let AutoRemove: Bool
                let NetworkMode: String?
            }
        }

        var exposed: [String: [String: String]] = [:]
        var bindings: [String: [[String: String]]] = [:]
        for port in request.ports where !port.container.isEmpty {
            let key = "\(port.container)/\(port.proto)"
            exposed[key] = [:]
            bindings[key, default: []].append(["HostPort": port.host])
        }
        let body = Body(
            Image: request.image,
            Cmd: request.command.trimmingCharacters(in: .whitespaces).isEmpty ? nil : shellWords(request.command),
            Env: request.env.filter { !$0.key.isEmpty }.map { "\($0.key)=\($0.value)" },
            ExposedPorts: exposed,
            HostConfig: .init(
                PortBindings: bindings,
                Binds: request.volumes.filter { !$0.source.isEmpty && !$0.target.isEmpty }
                    .map { "\($0.source):\($0.target)\($0.readOnly ? ":ro" : "")" },
                RestartPolicy: ["Name": request.autoRemove ? "no" : request.restart],
                AutoRemove: request.autoRemove,
                NetworkMode: request.network.isEmpty ? nil : request.network
            )
        )
        let name = request.name.trimmingCharacters(in: .whitespaces)
        let path = "/containers/create" + (name.isEmpty ? "" : "?name=\(name.urlEscaped)")

        struct Created: Decodable { let Id: String }
        let data: Data
        do {
            data = try await api.send("POST", path, json: body)
        } catch let error as DockerAPIError where error.status == 404 {
            try await api.streamLines("POST", "/images/create?fromImage=\(Self.tagged(request.image).urlEscaped)") { _ in }
            data = try await api.send("POST", path, json: body)
        }
        let id = try JSONDecoder().decode(Created.self, from: data).Id
        try await api.send("POST", "/containers/\(id)/start")
        await refresh()
        return id
    }

    private static func tagged(_ image: String) -> String {
        let last = image.split(separator: "/").last ?? ""
        return last.contains(":") || image.contains("@") ? image : image + ":latest"
    }

    // MARK: - Exec and files

    struct ExecResult {
        let output: String
        let exitCode: Int
    }

    /// Runs a command in a running container and collects its combined output.
    func exec(_ id: Container.ID, _ command: [String]) async throws -> ExecResult {
        guard let api else { throw DockerAPIError(status: 0, message: "Docker engine is not running") }
        struct Create: Encodable {
            let AttachStdout = true
            let AttachStderr = true
            let Tty = false
            let Cmd: [String]
        }
        struct Created: Decodable { let Id: String }
        struct Inspect: Decodable { let ExitCode: Int? }

        let created = try JSONDecoder().decode(
            Created.self, from: try await api.send("POST", "/containers/\(id)/exec", json: Create(Cmd: command))
        )
        var demuxer = LogDemuxer()
        var output = ""
        try await api.stream("POST", "/exec/\(created.Id)/start", body: Data(#"{"Detach":false,"Tty":false}"#.utf8)) { chunk in
            for frame in demuxer.feed(chunk) { output += String(decoding: frame.data, as: UTF8.self) }
        }
        let info: Inspect = try await api.get("/exec/\(created.Id)/json")
        return ExecResult(output: output, exitCode: info.ExitCode ?? 0)
    }

    func listFiles(_ id: Container.ID, path: String) async throws -> [FileEntry] {
        let result = try await exec(id, ["sh", "-c", FileEntry.listScript, "sh", path])
        if result.exitCode == 2 { throw DockerAPIError(status: 0, message: "Can't open \(path)") }
        if result.output.contains("executable file not found") {
            throw DockerAPIError(status: 0, message: "This container has no shell, so its files can't be listed.")
        }
        return FileEntry.parse(result.output, in: path)
    }

    /// Copies a file or folder out of a container (running or not) with `docker cp`.
    func download(_ id: Container.ID, path: String) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try await Shell.run("docker", ["cp", "\(id):\(path)", url.path])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }

    /// Opens an interactive shell in Ghostty, or Terminal when Ghostty isn't installed.
    func openTerminal(_ container: Container) {
        let docker = Shell.executable("docker")
        let shell = "command -v bash >/dev/null && exec bash || exec sh"
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        if FileManager.default.fileExists(atPath: ghostty.path) {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.arguments = ["-e", docker, "exec", "-it", container.id, "sh", "-c", shell]
            NSWorkspace.shared.openApplication(at: ghostty, configuration: config)
        } else {
            let command = "\(docker) exec -it \(container.id) sh -c '\(shell)'"
            let script = "tell application \"Terminal\" to do script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\""
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}

/// Splits Docker's multiplexed stream (8-byte header: stream, 0, 0, 0, big-endian length) into frames.
struct LogDemuxer {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) -> [(isError: Bool, data: Data)] {
        buffer.append(chunk)
        var frames: [(Bool, Data)] = []
        while buffer.count >= 8 {
            let start = buffer.startIndex
            let length = buffer[start + 4..<start + 8].reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 8 + length else { break }
            frames.append((buffer[start] == 2, Data(buffer[start + 8..<start + 8 + length])))
            buffer.removeSubrange(start..<start + 8 + length)
        }
        return frames
    }
}

/// Follows a container's log; lines are kept up to a limit.
@MainActor
@Observable
final class LogSession {
    private(set) var lines: [LogLine] = []
    private(set) var error: String?
    private(set) var isFollowing = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var nextID = 0
    private let limit = 5000

    func start(api: DockerAPI, id: String, tty: Bool, tail: Int = 500) {
        stop()
        lines = []
        error = nil
        isFollowing = true
        task = Task { [weak self] in
            var demuxer = LogDemuxer()
            var pending: [Bool: String] = [:]
            do {
                try await api.stream("GET", "/containers/\(id)/logs?follow=1&stdout=1&stderr=1&timestamps=1&tail=\(tail)") { chunk in
                    let frames = tty ? [(isError: false, data: chunk)] : demuxer.feed(chunk)
                    var ready: [(Bool, String)] = []
                    for frame in frames {
                        var text = pending[frame.isError, default: ""] + String(decoding: frame.data, as: UTF8.self)
                        while let nl = text.firstIndex(of: "\n") {
                            ready.append((frame.isError, String(text[..<nl])))
                            text = String(text[text.index(after: nl)...])
                        }
                        pending[frame.isError] = text
                    }
                    guard !ready.isEmpty else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(ready) } }
                }
            } catch is CancellationError {
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isFollowing = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func clear() {
        lines = []
    }

    private func append(_ raw: [(Bool, String)]) {
        for (isError, line) in raw {
            let clean = strippingANSI(line.hasSuffix("\r") ? String(line.dropLast()) : line)
            // Timestamps come first: "2026-09-16T23:17:19.359075463Z message".
            var timestamp: String?
            var text = clean
            if let space = clean.firstIndex(of: " "), clean[..<space].hasSuffix("Z") {
                timestamp = String(clean[..<space])
                text = String(clean[clean.index(after: space)...])
            }
            lines.append(LogLine(id: nextID, isError: isError, timestamp: timestamp, text: text))
            nextID += 1
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}

/// Streams stats for one container and keeps the last couple of minutes for charts.
@MainActor
@Observable
final class StatsSession {
    private(set) var samples: [StatsSample] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    var latest: StatsSample? { samples.last }

    func start(api: DockerAPI, id: String) {
        stop()
        samples = []
        task = Task { [weak self] in
            try? await api.streamLines("GET", "/containers/\(id)/stats?stream=true") { line in
                guard let response = try? JSONDecoder().decode(StatsResponse.self, from: line),
                      let sample = StatsSample(response) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.samples.append(sample)
                        if self.samples.count > 120 { self.samples.removeFirst() }
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
