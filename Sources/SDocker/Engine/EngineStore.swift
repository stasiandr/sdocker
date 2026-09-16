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
        guard state != .starting else { return }
        state = .starting
        startLog = ""
        Task {
            let process = LineProcess("colima", ["start"])
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

    /// Colima logs as logfmt (`time=… level=info msg="…"`); keep just the message.
    private static func readable(_ line: String) -> String {
        guard let range = line.range(of: "msg=\"") else { return line }
        var msg = line[range.upperBound...]
        if let end = msg.lastIndex(of: "\"") { msg = msg[..<end] }
        return String(msg)
    }
}
