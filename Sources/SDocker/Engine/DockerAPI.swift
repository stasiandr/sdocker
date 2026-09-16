import Foundation

struct DockerAPIError: LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? { message.isEmpty ? "Docker API returned \(status)" : message }
}

/// Minimal HTTP/1.1 client for the Docker Engine API over its unix socket.
/// One connection per request (`Connection: close`); reads block on a background queue.
struct DockerAPI: Sendable {
    let socketPath: String

    private static let queue = DispatchQueue(label: "sdocker.api", attributes: .concurrent)

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let data = try await send("GET", path)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var collected = Data()
        let status = try await exchange(method, path, body: body) { collected.append($0) }
        guard (200..<300).contains(status) else { throw Self.error(status: status, body: collected) }
        return collected
    }

    /// Streams a JSON-lines response (pull progress and friends), one decoded object per line.
    func streamLines(_ method: String, _ path: String, onLine: @escaping @Sendable (Data) -> Void) async throws {
        var buffer = Data()
        var ok = true
        let status = try await exchange(method, path, body: nil) { chunk in
            buffer.append(chunk)
            guard ok else { return }
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if !line.isEmpty { onLine(Data(line)) }
            }
        } onStatus: { ok = (200..<300).contains($0) }
        if !(200..<300).contains(status) {
            throw Self.error(status: status, body: buffer)
        }
        if !buffer.isEmpty { onLine(buffer) }
    }

    private static func error(status: Int, body: Data) -> DockerAPIError {
        struct Message: Decodable { let message: String }
        let message = (try? JSONDecoder().decode(Message.self, from: body))?.message
            ?? String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return DockerAPIError(status: status, message: message)
    }

    // MARK: - Wire

    private func exchange(
        _ method: String, _ path: String, body: Data?,
        onBody: @escaping (Data) -> Void,
        onStatus: @escaping (Int) -> Void = { _ in }
    ) async throws -> Int {
        let socketPath = socketPath
        return try await withCheckedThrowingContinuation { cont in
            Self.queue.async {
                do {
                    let status = try Self.blockingExchange(
                        socketPath: socketPath, method: method, path: path, body: body,
                        onStatus: onStatus, onBody: onBody
                    )
                    cont.resume(returning: status)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func blockingExchange(
        socketPath: String, method: String, path: String, body: Data?,
        onStatus: @escaping (Int) -> Void, onBody: @escaping (Data) -> Void
    ) throws -> Int {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED) }

        var head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        } else if method == "POST" {
            head += "Content-Length: 0\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }
        try request.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EPIPE) }
                offset += n
            }
        }

        var reader = ResponseReader(onStatus: onStatus, onBody: onBody)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !reader.isDone {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            try reader.feed(Data(chunk[0..<n]))
        }
        guard reader.status > 0 else { throw DockerAPIError(status: 0, message: "Empty response from Docker") }
        return reader.status
    }
}

/// Incremental HTTP/1.1 response parser: headers, then a plain, sized or chunked body.
private struct ResponseReader {
    let onStatus: (Int) -> Void
    let onBody: (Data) -> Void
    private(set) var status = 0
    private(set) var isDone = false

    private var buffer = Data()
    private var headersParsed = false
    private var chunked = false
    private var remaining: Int?        // Content-Length left, or bytes left in the current chunk
    private var awaitingChunkSize = true

    init(onStatus: @escaping (Int) -> Void, onBody: @escaping (Data) -> Void) {
        self.onStatus = onStatus
        self.onBody = onBody
    }

    mutating func feed(_ data: Data) throws {
        buffer.append(data)
        if !headersParsed {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
                if name == "content-length" { remaining = Int(value) }
            }
            headersParsed = true
            onStatus(status)
            if status == 204 || status == 304 || (!chunked && remaining == 0) { isDone = true }
        }
        if chunked { try drainChunked() } else { drainPlain() }
    }

    private mutating func drainPlain() {
        guard !buffer.isEmpty else { return }
        if let left = remaining {
            let take = min(left, buffer.count)
            onBody(buffer.prefix(take))
            buffer.removeFirst(take)
            remaining = left - take
            if remaining == 0 { isDone = true }
        } else {
            onBody(buffer)
            buffer.removeAll()
        }
    }

    private mutating func drainChunked() throws {
        while !isDone {
            if awaitingChunkSize {
                guard let crlf = buffer.range(of: Data("\r\n".utf8)) else { return }
                let line = String(decoding: buffer[buffer.startIndex..<crlf.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<crlf.upperBound)
                if line.isEmpty { continue }  // CRLF trailing the previous chunk
                let hex = line.split(separator: ";").first.map(String.init) ?? ""
                guard let size = Int(hex, radix: 16) else {
                    throw DockerAPIError(status: status, message: "Malformed chunked response")
                }
                if size == 0 { isDone = true; return }
                remaining = size
                awaitingChunkSize = false
            }
            guard let left = remaining, !buffer.isEmpty else { return }
            let take = min(left, buffer.count)
            onBody(buffer.prefix(take))
            buffer.removeFirst(take)
            remaining = left - take
            if remaining == 0 { awaitingChunkSize = true }
        }
    }
}

extension String {
    /// Percent-encodes a value for a query string or a path segment.
    var urlEscaped: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
