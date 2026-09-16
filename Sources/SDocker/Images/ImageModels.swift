import Foundation

/// `GET /images/json?manifests=1`
struct ImageSummary: Decodable, Sendable {
    let Id: String
    let RepoTags: [String]?
    let RepoDigests: [String]?
    let Created: Int64
    let Size: Int64
    let Containers: Int
    let Labels: [String: String]?
    let Manifests: [Manifest]?

    struct Manifest: Decodable, Sendable {
        let Kind: String?
        let ImageData: ImageData?

        struct ImageData: Decodable, Sendable {
            let Platform: Platform?
        }
    }

    struct Platform: Decodable, Sendable {
        let architecture: String
        let os: String
        let variant: String?

        var name: String { [os, architecture, variant].compactMap { $0 }.joined(separator: "/") }
    }
}

/// One row of the images table: an image under one of its tags (or untagged).
struct ImageRow: Identifiable, Hashable, Sendable {
    let id: String          // image id + tag, unique per row
    let imageID: String
    let repository: String
    let tag: String
    let created: Date
    let size: Int64
    let platforms: [String]
    let inUse: Bool

    var isDangling: Bool { tag == "<none>" }
    var reference: String { isDangling ? imageID : "\(repository):\(tag)" }
    var shortID: String { String(imageID.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }

    static func rows(from summary: ImageSummary, usedImageIDs: Set<String>) -> [ImageRow] {
        let tags = (summary.RepoTags ?? []).filter { $0 != "<none>:<none>" }
        let platforms = (summary.Manifests ?? [])
            .filter { $0.Kind == "image" }
            .compactMap { $0.ImageData?.Platform?.name }
        let base = { (repo: String, tag: String) in
            ImageRow(
                id: "\(summary.Id)|\(repo):\(tag)", imageID: summary.Id, repository: repo, tag: tag,
                created: Date(timeIntervalSince1970: TimeInterval(summary.Created)), size: summary.Size,
                platforms: platforms, inUse: summary.Containers > 0 || usedImageIDs.contains(summary.Id)
            )
        }
        if tags.isEmpty {
            let repo = summary.RepoDigests?.first.map { String($0.split(separator: "@")[0]) } ?? "<none>"
            return [base(repo, "<none>")]
        }
        return tags.map { ref in
            // The tag follows the last colon that isn't part of a registry host:port.
            if let colon = ref.lastIndex(of: ":"), !ref[colon...].contains("/") {
                return base(String(ref[..<colon]), String(ref[ref.index(after: colon)...]))
            }
            return base(ref, "latest")
        }
    }
}

/// `GET /images/{id}/json`
struct ImageInspect: Decodable, Sendable {
    let Id: String
    let RepoTags: [String]?
    let RepoDigests: [String]?
    let Created: String?
    let Architecture: String?
    let Os: String?
    let Variant: String?
    let Size: Int64?
    let Author: String?
    let Config: Config?

    struct Config: Decodable, Sendable {
        let Env: [String]?
        let Cmd: [String]?
        let Entrypoint: [String]?
        let WorkingDir: String?
        let User: String?
        let ExposedPorts: [String: EmptyObject]?
        let Volumes: [String: EmptyObject]?
        let Labels: [String: String]?
    }

    struct EmptyObject: Decodable, Sendable {}
}

/// `GET /images/{id}/history`
struct ImageLayer: Decodable, Identifiable, Sendable {
    let Id: String
    let Created: Int64
    let CreatedBy: String
    let Size: Int64
    let Comment: String?

    var id: String { "\(Created)-\(CreatedBy)-\(Size)" }

    /// The Dockerfile instruction without shell wrapping, like Docker Hub's layer view.
    var instruction: String {
        // Collapse the line continuations and indentation of multi-line RUN instructions.
        var text = CreatedBy.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.hasSuffix(" # buildkit") { text.removeLast(" # buildkit".count) }
        if let nop = text.range(of: "/bin/sh -c #(nop) ") {
            // Legacy builder metadata instruction: ENV, CMD, LABEL…
            return String(text[nop.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let shell = text.range(of: "/bin/sh -c ") {
            // "RUN /bin/sh -c …" from BuildKit, "|2 ARG=… /bin/sh -c …" from the legacy builder.
            return "RUN " + text[shell.upperBound...]
        }
        return text
    }
}

/// One JSON line of `POST /images/create`.
struct PullMessage: Decodable, Sendable {
    let status: String?
    let id: String?
    let progressDetail: Detail?
    let error: String?

    struct Detail: Decodable, Sendable {
        let current: Int64?
        let total: Int64?
    }
}
