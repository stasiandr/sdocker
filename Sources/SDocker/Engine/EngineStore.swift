import Foundation
import Observation

/// Tracks the Colima VM and the Docker daemon inside it.
@MainActor
@Observable
final class EngineStore {
    enum State: Equatable {
        case checking
        case stopped
        case starting
        case stopping
        case running
        case failed(String)
    }

    struct Info: Decodable {
        let ServerVersion: String
        let NCPU: Int
        let MemTotal: Int64
        let Images: Int
        let Containers: Int
        let Driver: String
    }

    private(set) var state: State = .checking
    private(set) var info: Info?
    /// Last lines from `colima start` while the VM boots.
    private(set) var startLog: String = ""
    private(set) var api: DockerAPI?
    private(set) var vm: VMConfig?

    /// Colima's VM settings from `~/.colima/default/colima.yaml`.
    struct VMConfig: Equatable {
        var cpus = 2
        var memoryGiB = 2
        var diskGiB = 100
        var vmType = ""
        var mountType = ""
        var arch = ""
    }

    init() {
        Task { await refresh() }
    }

    var isRunning: Bool { state == .running }

    var statusText: String {
        switch state {
        case .checking: "Checking…"
        case .stopped: "Engine stopped"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .running: "Engine running"
        case .failed: "Engine unavailable"
        }
    }

    func refresh() async {
        vm = Self.readVMConfig()
        guard state != .starting, state != .stopping else { return }
        let socket = await Self.dockerSocket()
        let api = DockerAPI(socketPath: socket)
        do {
            info = try await api.get("/info")
            self.api = api
            state = .running
        } catch {
            info = nil
            self.api = nil
            state = Shell.executable("colima") == "colima" ? .failed("colima is not installed") : .stopped
        }
    }

    func start() {
        start(arguments: [])
    }

    /// Stops the VM if needed and starts it with new resources; Colima saves them in its config.
    func apply(cpus: Int, memoryGiB: Int, diskGiB: Int) {
        let arguments = ["--cpu", "\(cpus)", "--memory", "\(memoryGiB)", "--disk", "\(diskGiB)"]
        guard isRunning else { return start(arguments: arguments) }
        state = .stopping
        Task {
            do {
                _ = try await Shell.run("colima", ["stop"])
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            state = .stopped
            start(arguments: arguments)
        }
    }

    private func start(arguments: [String]) {
        guard state != .starting else { return }
        state = .starting
        startLog = ""
        Task {
            let process = LineProcess("colima", ["start"] + arguments)
            do {
                try process.start { line in
                    self.startLog = Self.readable(line)
                } onExit: { status in
                    self.state = .checking
                    Task {
                        await self.refresh()
                        if status != 0, self.state != .running {
                            self.state = .failed(self.startLog.isEmpty ? "colima start failed" : self.startLog)
                        }
                    }
                }
                self.process = process
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        state = .stopping
        Task {
            do {
                _ = try await Shell.run("colima", ["stop"])
            } catch {
                state = .failed(error.localizedDescription)
                return
            }
            state = .checking
            await refresh()
        }
    }

    @ObservationIgnored private var process: LineProcess?

    /// The daemon socket of the current docker context, falling back to Colima's default.
    private static func dockerSocket() async -> String {
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            return String(host.dropFirst("unix://".count))
        }
        if let data = try? await Shell.run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]) {
            let host = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if host.hasPrefix("unix://") { return String(host.dropFirst("unix://".count)) }
        }
        return NSHomeDirectory() + "/.colima/default/docker.sock"
    }

    private static func readVMConfig() -> VMConfig? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.colima/default/colima.yaml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var config = VMConfig()
        // Only top-level scalar keys are needed, so a line scan is enough.
        for line in text.split(separator: "\n") where !line.hasPrefix(" ") && !line.hasPrefix("#") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch parts[0] {
            case "cpu": config.cpus = Int(value) ?? config.cpus
            case "memory": config.memoryGiB = Int(Double(value) ?? Double(config.memoryGiB))
            case "disk": config.diskGiB = Int(value) ?? config.diskGiB
            case "vmType": config.vmType = value
            case "mountType": config.mountType = value
            case "arch": config.arch = value
            default: break
            }
        }
        return config
    }

    /// Colima logs as logfmt (`time=… level=info msg="…"`); keep just the message.
    private static func readable(_ line: String) -> String {
        guard let range = line.range(of: "msg=\"") else { return line }
        var msg = line[range.upperBound...]
        if let end = msg.lastIndex(of: "\"") { msg = msg[..<end] }
        return String(msg)
    }
}
