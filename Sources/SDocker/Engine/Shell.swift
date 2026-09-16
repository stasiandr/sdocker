import Foundation

struct ShellError: LocalizedError {
    let command: String
    let status: Int32
    let output: String

    var errorDescription: String? {
        let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "\(command) exited with \(status)" : tail
    }
}

/// Runs the docker and colima CLIs. A GUI app doesn't inherit the shell PATH, so it's set here.
enum Shell {
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func executable(_ name: String) -> String {
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return name
    }

    static func makeProcess(_ tool: String, _ args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable(tool))
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        process.environment = env
        return process
    }

    /// Runs to completion and returns stdout (or stderr, for tools that print their data there);
    /// throws with stderr on a non-zero exit.
    static func run(_ tool: String, _ args: [String], outputOnStderr: Bool = false) async throws -> Data {
        let process = makeProcess(tool, args)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { cont in
            // Read both pipes concurrently so a chatty stderr can't fill up and block the child.
            let group = DispatchGroup()
            let stdout = Collected(), stderr = Collected()
            group.enter()
            DispatchQueue.global().async { stdout.data = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            group.enter()
            DispatchQueue.global().async { stderr.data = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            process.terminationHandler = { p in
                group.notify(queue: .global()) {
                    if p.terminationStatus == 0 {
                        cont.resume(returning: outputOnStderr ? stderr.data : stdout.data)
                    } else {
                        let command = ([tool] + args).joined(separator: " ")
                        cont.resume(throwing: ShellError(
                            command: command, status: p.terminationStatus,
                            output: String(decoding: stderr.data, as: UTF8.self)
                        ))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    /// Splits JSON-lines output into decoded values, skipping lines that don't decode.
    static func decodeLines<T: Decodable>(_ data: Data, as type: T.Type = T.self) -> [T] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }
}

/// Pipe contents filled by one reader thread and read after the group finishes.
private final class Collected: @unchecked Sendable {
    var data = Data()
}

/// A long-running process whose output arrives line by line on the main actor.
@MainActor
final class LineProcess {
    private let process: Process

    init(_ tool: String, _ args: [String], currentDirectory: URL? = nil) {
        process = Shell.makeProcess(tool, args)
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    }

    /// Starts the process; `onLine` gets every stdout and stderr line, `onExit` the exit status.
    func start(onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        var pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                        pending.removeAll()
                        return
                    }
                    pending.append(chunk)
                    while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        onLine(String(decoding: line, as: UTF8.self))
                    }
                }
            }
        }
        process.terminationHandler = { p in
            let status = p.terminationStatus
            // Let the readability handler flush the tail before reporting the exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { onExit(status) }
            }
        }
        try process.run()
    }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }
}
