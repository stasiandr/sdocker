import Foundation
import Observation

/// One line of BuildKit's `--progress rawjson` output (a SolveStatus).
struct SolveStatus: Decodable {
    struct Vertex: Decodable {
        let digest: String
        let name: String?
        let started: String?
        let completed: String?
        let cached: Bool?
        let error: String?
    }

    struct VertexStatus: Decodable {
        let id: String
        let vertex: String
        let name: String?
        let current: Int64?
        let total: Int64?
        let completed: String?
    }

    struct Log: Decodable {
        let vertex: String
        let data: String
    }

    struct Warning: Decodable {
        let vertex: String
        let short: String?
    }

    let vertexes: [Vertex]?
    let statuses: [VertexStatus]?
    let logs: [Log]?
    let warnings: [Warning]?
}

/// A build step (BuildKit vertex) folded from the rawjson stream.
@Observable
final class BuildStep: Identifiable {
    let id: String
    let number: Int
    var name = ""
    var started: Date?
    var completed: Date?
    var cached = false
    var error: String?
    var log = ""
    /// Sub-tasks: "transferring context", "extracting sha256:…", with byte counts.
    var tasks: [(id: String, current: Int64, total: Int64?, done: Bool)] = []
    var warnings: [String] = []

    init(id: String, number: Int) {
        self.id = id
        self.number = number
    }

    var isInternal: Bool { name.hasPrefix("[internal]") || name.hasPrefix("[auth]") }
    var isRunning: Bool { started != nil && completed == nil }

    var duration: TimeInterval? {
        guard let started else { return nil }
        return (completed ?? .now).timeIntervalSince(started)
    }
}

/// Folds a rawjson progress stream into ordered steps with their logs.
@Observable
final class BuildProgress {
    private(set) var steps: [BuildStep] = []
    @ObservationIgnored private var index: [String: BuildStep] = [:]
    @ObservationIgnored private let decoder = JSONDecoder()

    var cachedCount: Int { steps.filter(\.cached).count }
    var failedStep: BuildStep? { steps.first { $0.error != nil } }

    /// Feeds one output line; lines that aren't rawjson are ignored and returned false.
    @discardableResult
    func consume(_ line: String) -> Bool {
        guard line.hasPrefix("{"), let status = try? decoder.decode(SolveStatus.self, from: Data(line.utf8)) else {
            return false
        }
        for v in status.vertexes ?? [] {
            let step = step(for: v.digest)
            if let name = v.name { step.name = name }
            if let started = ISO8601DateFormatter.parse(v.started) {
                // BuildKit restarts a vertex when it's re-evaluated; keep the earliest start.
                if step.started == nil || started < step.started! { step.started = started }
            }
            step.completed = ISO8601DateFormatter.parse(v.completed) ?? (v.started != nil ? nil : step.completed)
            if v.cached == true { step.cached = true }
            if let error = v.error, !error.isEmpty { step.error = error }
        }
        for s in status.statuses ?? [] {
            let step = step(for: s.vertex)
            let task = (id: s.id, current: s.current ?? 0, total: s.total, done: s.completed != nil)
            if let i = step.tasks.firstIndex(where: { $0.id == s.id }) {
                step.tasks[i] = task
            } else {
                step.tasks.append(task)
            }
        }
        for log in status.logs ?? [] {
            guard let data = Data(base64Encoded: log.data) else { continue }
            step(for: log.vertex).log += String(decoding: data, as: UTF8.self)
        }
        for warning in status.warnings ?? [] {
            if let short = warning.short, let data = Data(base64Encoded: short) {
                step(for: warning.vertex).warnings.append(String(decoding: data, as: UTF8.self))
            }
        }
        return true
    }

    /// The whole build as plain text, in the format of `--progress plain`.
    var plainLog: String {
        steps.map { step in
            var text = "#\(step.number) \(step.name)\n"
            for line in step.log.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                text += "#\(step.number) \(line)\n"
            }
            if let error = step.error {
                text += "#\(step.number) ERROR: \(error)\n"
            } else if step.cached {
                text += "#\(step.number) CACHED\n"
            } else if let duration = step.duration, step.completed != nil {
                text += "#\(step.number) DONE \(String(format: "%.1fs", duration))\n"
            }
            return text
        }
        .joined(separator: "\n")
    }

    private func step(for digest: String) -> BuildStep {
        if let step = index[digest] { return step }
        let step = BuildStep(id: digest, number: steps.count + 1)
        index[digest] = step
        steps.append(step)
        return step
    }
}
