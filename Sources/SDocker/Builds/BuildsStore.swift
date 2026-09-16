import Foundation
import Observation

/// `docker buildx history ls --format json`
struct BuildRecord: Decodable, Sendable {
    let name: String
    let ref: String
    let status: String
    let created_at: String?
    let completed_at: String?
    let total_steps: Int?
    let completed_steps: Int?
    let cached_steps: Int?

    /// The record id without the builder/node prefix, as `history inspect` wants it.
    var shortRef: String { String(ref.split(separator: "/").last ?? Substring(ref)) }
}

/// `docker buildx history inspect --format json`
struct BuildInspect: Decodable, Sendable {
    let Name: String?
    let Context: String?
    let Dockerfile: String?
    let Target: String?
    let Platform: [String]?
    let Tags: [String]?
    let BuildArgs: [KeyValue]?
    let Labels: [KeyValue]?
    let Status: String?
    let Error: BuildError?
    let Materials: [Material]?
    let Config: [String: AnyScalar]?

    struct KeyValue: Decodable, Sendable {
        let Name: String
        let Value: String
    }

    struct BuildError: Decodable, Sendable {
        let Message: String?
        let Name: String?
        let Sources: String?

        var sources: String? {
            Sources.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
        }
    }

    struct Material: Decodable, Sendable {
        let URI: String
    }

    /// Config values are strings or flags; keep them printable.
    struct AnyScalar: Decodable, Sendable, CustomStringConvertible {
        let description: String

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { description = s }
            else if let b = try? c.decode(Bool.self) { description = String(b) }
            else if let n = try? c.decode(Double.self) { description = String(n) }
            else { description = "…" }
        }
    }
}

enum BuildStatus: Equatable {
    case running, completed, failed, canceled

    init(_ raw: String) {
        switch raw.lowercased() {
        case "completed": self = .completed
        case "running": self = .running
        case "canceled", "cancelled": self = .canceled
        default: self = .failed
        }
    }
}

/// What to build; also used to prefill "Build Again".
struct BuildRequest: Hashable {
    var context: URL
    var dockerfile = ""                      // relative to the context; empty = Dockerfile
    var tags: [String] = []
    var buildArgs: [String: String] = [:]
    var target = ""
    var platforms: [String] = []
    var noCache = false
    var pull = false

    var displayName: String {
        var name = context.lastPathComponent
        if !dockerfile.isEmpty, dockerfile != "Dockerfile" { name += "/" + dockerfile }
        if !target.isEmpty { name += " (\(target))" }
        return name
    }
}

/// A build started from this app, streamed live.
@MainActor
@Observable
final class BuildSession: Identifiable {
    let id = UUID()
    let request: BuildRequest
    let startedAt = Date()
    let progress = BuildProgress()
    var status = BuildStatus.running
    var finishedAt: Date?
    var ref: String?
    /// Non-rawjson output: the final error summary and CLI warnings.
    var messages: [String] = []

    @ObservationIgnored fileprivate var process: LineProcess?

    init(request: BuildRequest) {
        self.request = request
    }
}

/// A row of the builds table: a live session or a record from BuildKit history.
struct BuildItem: Identifiable, Hashable {
    let id: String
    let name: String
    let status: BuildStatus
    let started: Date?
    let duration: TimeInterval?
    let totalSteps: Int
    let cachedSteps: Int
    let sessionID: UUID?
    let ref: String?
}

@MainActor
@Observable
final class BuildsStore {
    private(set) var records: [BuildRecord] = []
    private(set) var sessions: [BuildSession] = []
    private(set) var isLoading = false
    private(set) var details: [String: BuildInspect] = [:]
    private(set) var recordProgress: [String: BuildProgress] = [:]
    var lastError: String?

    var items: [BuildItem] {
        let sessionRefs = Set(sessions.compactMap(\.ref))
        let live = sessions.map { s in
            BuildItem(
                id: s.id.uuidString, name: s.request.displayName, status: s.status, started: s.startedAt,
                duration: (s.finishedAt ?? .now).timeIntervalSince(s.startedAt),
                totalSteps: s.progress.steps.count, cachedSteps: s.progress.cachedCount,
                sessionID: s.id, ref: s.ref
            )
        }
        let history = records.filter { !sessionRefs.contains($0.shortRef) }.map { r in
            let started = ISO8601DateFormatter.parse(r.created_at)
            let completed = ISO8601DateFormatter.parse(r.completed_at)
            return BuildItem(
                id: r.shortRef, name: r.name, status: BuildStatus(r.status), started: started,
                duration: started.map { (completed ?? .now).timeIntervalSince($0) },
                totalSteps: r.total_steps ?? 0, cachedSteps: r.cached_steps ?? 0, sessionID: nil, ref: r.shortRef
            )
        }
        return (live + history).sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
    }

    var runningCount: Int { sessions.filter { $0.status == .running }.count }

    func session(_ id: UUID?) -> BuildSession? {
        sessions.first { $0.id == id }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await Shell.run("docker", ["buildx", "history", "ls", "--format", "json"])
            records = Shell.decodeLines(data)
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }

    // MARK: - History record details

    func loadDetails(ref: String) async {
        async let inspect = Shell.run("docker", ["buildx", "history", "inspect", ref, "--format", "json"])
        async let logs = Shell.run("docker", ["buildx", "history", "logs", "--progress", "rawjson", ref], outputOnStderr: true)
        do {
            details[ref] = try JSONDecoder().decode(BuildInspect.self, from: try await inspect)
            let progress = BuildProgress()
            for line in String(decoding: try await logs, as: UTF8.self).split(separator: "\n") {
                progress.consume(String(line))
            }
            recordProgress[ref] = progress
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }

    func remove(refs: [String]) async {
        guard !refs.isEmpty else { return }
        do {
            _ = try await Shell.run("docker", ["buildx", "history", "rm"] + refs)
        } catch {
            lastError = message(for: error) ?? lastError
        }
        sessions.removeAll { $0.ref.map(refs.contains) ?? false && $0.status != .running }
        await refresh()
    }

    // MARK: - Running builds

    @discardableResult
    func start(_ request: BuildRequest) -> BuildSession {
        let session = BuildSession(request: request)
        let metadata = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdocker-build-\(session.id.uuidString).json")

        var args = ["buildx", "build", "--progress", "rawjson", "--metadata-file", metadata.path]
        if !request.dockerfile.isEmpty {
            args += ["--file", request.context.appendingPathComponent(request.dockerfile).path]
        }
        for tag in request.tags { args += ["--tag", tag] }
        for (key, value) in request.buildArgs.sorted(by: { $0.key < $1.key }) { args += ["--build-arg", "\(key)=\(value)"] }
        if !request.target.isEmpty { args += ["--target", request.target] }
        if !request.platforms.isEmpty { args += ["--platform", request.platforms.joined(separator: ",")] }
        if request.noCache { args.append("--no-cache") }
        if request.pull { args.append("--pull") }
        args += ["--load", request.context.path]

        let process = LineProcess("docker", args, currentDirectory: request.context)
        session.process = process
        sessions.append(session)
        do {
            try process.start { line in
                if !session.progress.consume(line), !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    session.messages.append(line)
                }
            } onExit: { [weak self] status in
                session.finishedAt = .now
                if session.status == .running { session.status = status == 0 ? .completed : .failed }
                session.process = nil
                Task { await self?.finish(session, metadata: metadata) }
            }
        } catch {
            session.status = .failed
            session.finishedAt = .now
            session.messages.append(error.localizedDescription)
        }
        return session
    }

    func cancel(_ session: BuildSession) {
        session.status = .canceled
        session.process?.interrupt()
    }

    private func finish(_ session: BuildSession, metadata: URL) async {
        struct Metadata: Decodable {
            let ref: String?
            enum CodingKeys: String, CodingKey { case ref = "buildx.build.ref" }
        }
        if let data = try? Data(contentsOf: metadata),
           let ref = try? JSONDecoder().decode(Metadata.self, from: data).ref {
            session.ref = String(ref.split(separator: "/").last ?? "")
        }
        try? FileManager.default.removeItem(at: metadata)
        await refresh()
        if session.ref == nil {
            // Failed builds don't write metadata: take the first record created after the session started.
            session.ref = records
                .compactMap { r in ISO8601DateFormatter.parse(r.created_at).map { (r, $0) } }
                .filter { $0.1 >= session.startedAt.addingTimeInterval(-1) }
                .min { $0.1 < $1.1 }?.0.shortRef
        }
        if let ref = session.ref {
            await loadDetails(ref: ref)
        }
    }
}
