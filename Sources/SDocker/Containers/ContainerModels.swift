import Foundation

/// `GET /containers/json?all=1`
struct ContainerSummary: Decodable, Sendable {
    let Id: String
    let Names: [String]
    let Image: String
    let ImageID: String
    let Command: String?
    let Created: Int64
    let Ports: [Port]?
    let Labels: [String: String]?
    let State: String
    let Status: String
    let Mounts: [Mount]?
    let NetworkSettings: Networks?

    struct Port: Decodable, Hashable, Sendable {
        let IP: String?
        let PrivatePort: Int
        let PublicPort: Int?
        let `Type`: String
    }

    struct Mount: Decodable, Hashable, Sendable {
        let `Type`: String
        let Name: String?
        let Source: String?
        let Destination: String
        let RW: Bool?
    }

    struct Networks: Decodable, Sendable {
        let Networks: [String: Endpoint]?

        struct Endpoint: Decodable, Sendable {
            let IPAddress: String?
            let NetworkID: String?
        }
    }
}

struct Container: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case running, paused, restarting, created, exited, dead, removing

        var isActive: Bool { self == .running || self == .paused || self == .restarting }
    }

    let id: String
    let name: String
    let image: String
    let imageID: String
    let command: String
    let created: Date
    let state: State
    let status: String
    /// Published ports, one per host port (IPv4 and IPv6 bindings collapsed).
    let ports: [ContainerSummary.Port]
    let exposedOnly: [Int]
    let mounts: [ContainerSummary.Mount]
    let networks: [String: String]      // network name → IP address
    let project: String?
    let service: String?

    var shortID: String { String(id.prefix(12)) }

    init(_ s: ContainerSummary) {
        id = s.Id
        name = s.Names.first.map { String($0.drop(while: { $0 == "/" })) } ?? String(s.Id.prefix(12))
        image = s.Image
        imageID = s.ImageID
        command = s.Command ?? ""
        created = Date(timeIntervalSince1970: TimeInterval(s.Created))
        state = State(rawValue: s.State) ?? .exited
        status = s.Status
        var seen = Set<String>()
        ports = (s.Ports ?? [])
            .filter { $0.PublicPort != nil }
            .filter { seen.insert("\($0.PublicPort!)/\($0.PrivatePort)/\($0.Type)").inserted }
            .sorted { $0.PrivatePort < $1.PrivatePort }
        exposedOnly = Array(Set((s.Ports ?? []).filter { $0.PublicPort == nil }.map(\.PrivatePort))).sorted()
        mounts = s.Mounts ?? []
        networks = (s.NetworkSettings?.Networks ?? [:]).mapValues { $0.IPAddress ?? "" }
        project = s.Labels?["com.docker.compose.project"]
        service = s.Labels?["com.docker.compose.service"]
    }
}

/// `GET /containers/{id}/json`, the parts shown in the Inspect tab.
struct ContainerInspect: Decodable, Sendable {
    let Id: String
    let Created: String?
    let Path: String?
    let Args: [String]?
    let State: StateInfo
    let RestartCount: Int?
    let Config: Config
    let HostConfig: HostConfig?
    let Mounts: [ContainerSummary.Mount]?

    struct StateInfo: Decodable, Sendable {
        let Status: String
        let ExitCode: Int?
        let Error: String?
        let StartedAt: String?
        let FinishedAt: String?
        let OOMKilled: Bool?
        let Health: Health?

        struct Health: Decodable, Sendable {
            let Status: String
        }
    }

    struct Config: Decodable, Sendable {
        let Hostname: String?
        let User: String?
        let Env: [String]?
        let Cmd: [String]?
        let Entrypoint: [String]?
        let WorkingDir: String?
        let Image: String?
        let Tty: Bool?
        let Labels: [String: String]?
    }

    struct HostConfig: Decodable, Sendable {
        let RestartPolicy: Restart?
        let AutoRemove: Bool?
        let NetworkMode: String?
        let Memory: Int64?
        let NanoCpus: Int64?

        struct Restart: Decodable, Sendable {
            let Name: String
        }
    }
}

/// `GET /containers/{id}/stats`
struct StatsResponse: Decodable, Sendable {
    let cpu_stats: CPU?
    let precpu_stats: CPU?
    let memory_stats: Memory?
    let networks: [String: Network]?
    let blkio_stats: Blkio?
    let pids_stats: Pids?

    struct CPU: Decodable, Sendable {
        let cpu_usage: Usage?
        let system_cpu_usage: UInt64?
        let online_cpus: Int?

        struct Usage: Decodable, Sendable {
            let total_usage: UInt64?
        }
    }

    struct Memory: Decodable, Sendable {
        let usage: UInt64?
        let limit: UInt64?
        let stats: [String: UInt64]?
    }

    struct Network: Decodable, Sendable {
        let rx_bytes: UInt64
        let tx_bytes: UInt64
    }

    struct Blkio: Decodable, Sendable {
        let io_service_bytes_recursive: [Entry]?

        struct Entry: Decodable, Sendable {
            let op: String
            let value: UInt64
        }
    }

    struct Pids: Decodable, Sendable {
        let current: Int?
    }
}

struct StatsSample: Sendable, Identifiable {
    let id = UUID()
    let date: Date
    let cpuPercent: Double
    let memoryUsed: Int64
    let memoryLimit: Int64
    let netRx: Int64
    let netTx: Int64
    let blockRead: Int64
    let blockWrite: Int64
    let pids: Int

    /// Returns nil for the first sample of a stream, which has no previous CPU reading.
    init?(_ r: StatsResponse, date: Date = .now) {
        guard let cpu = r.cpu_stats, let total = cpu.cpu_usage?.total_usage, let system = cpu.system_cpu_usage else {
            return nil
        }
        let prevTotal = r.precpu_stats?.cpu_usage?.total_usage ?? 0
        let prevSystem = r.precpu_stats?.system_cpu_usage ?? 0
        guard prevSystem > 0, system > prevSystem else { return nil }
        let cpuDelta = Double(total &- prevTotal)
        let systemDelta = Double(system - prevSystem)
        self.date = date
        cpuPercent = max(0, cpuDelta / systemDelta * Double(cpu.online_cpus ?? 1) * 100)
        // Like `docker stats`: page cache that can be dropped doesn't count as used.
        let usage = r.memory_stats?.usage ?? 0
        let cache = r.memory_stats?.stats?["inactive_file"] ?? r.memory_stats?.stats?["total_inactive_file"] ?? 0
        memoryUsed = Int64(usage > cache ? usage - cache : usage)
        memoryLimit = Int64(r.memory_stats?.limit ?? 0)
        netRx = Int64(r.networks?.values.reduce(0) { $0 + $1.rx_bytes } ?? 0)
        netTx = Int64(r.networks?.values.reduce(0) { $0 + $1.tx_bytes } ?? 0)
        let io = r.blkio_stats?.io_service_bytes_recursive ?? []
        blockRead = Int64(io.filter { $0.op.lowercased() == "read" }.reduce(0) { $0 + $1.value })
        blockWrite = Int64(io.filter { $0.op.lowercased() == "write" }.reduce(0) { $0 + $1.value })
        pids = r.pids_stats?.current ?? 0
    }
}

struct LogLine: Identifiable, Sendable {
    let id: Int
    let isError: Bool
    let timestamp: String?
    let text: String
}

/// A file or folder listed inside a container or a volume.
struct FileEntry: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case directory, file, link, other }

    var id: String { path }
    let path: String
    let name: String
    let kind: Kind
    let size: Int64
    let modified: Date?

    /// Parses `stat -c '%F|%s|%Y|%n'` output.
    static func parse(_ output: String, in directory: String) -> [FileEntry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            let path = String(parts[3])
            let name = (path as NSString).lastPathComponent
            guard name != "." && name != ".." else { return nil }
            let kind: Kind = switch parts[0] {
            case "directory": .directory
            case "symbolic link": .link
            case _ where parts[0].contains("regular"): .file
            default: .other
            }
            return FileEntry(
                path: path, name: name, kind: kind, size: Int64(parts[1]) ?? 0,
                modified: TimeInterval(parts[2]).map { Date(timeIntervalSince1970: $0) }
            )
        }
        .sorted { ($0.kind == .directory ? 0 : 1, $0.name.lowercased()) < ($1.kind == .directory ? 0 : 1, $1.name.lowercased()) }
    }

    /// A shell snippet listing `$1`, including dotfiles; works with GNU and BusyBox stat.
    static let listScript = #"cd "$1" 2>/dev/null || exit 2; for f in * .[!.]* ..?*; do [ -e "$f" ] || [ -L "$f" ] || continue; stat -c '%F|%s|%Y|%n' "$1/$f" 2>/dev/null | sed 's#//#/#'; done"#
}

/// Splits a command line into words, honouring single and double quotes.
func shellWords(_ line: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var inWord = false
    for ch in line {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            inWord = true
        } else if ch.isWhitespace {
            if inWord { words.append(current); current = ""; inWord = false }
        } else {
            current.append(ch)
            inWord = true
        }
    }
    if inWord { words.append(current) }
    return words
}

/// Removes ANSI escape sequences (colors, cursor moves) from log output.
func strippingANSI(_ text: String) -> String {
    guard text.contains("\u{1B}") else { return text }
    return text.replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
}
