import Foundation
import Observation

/// Space used by Docker (`/system/df`) and by the VM disk it lives on.
@MainActor
@Observable
final class DiskStore {
    struct Category: Identifiable {
        enum Kind: String, CaseIterable {
            case images = "Images"
            case containers = "Containers"
            case volumes = "Volumes"
            case buildCache = "Build cache"
        }

        var id: Kind { kind }
        let kind: Kind
        let total: Int64
        let reclaimable: Int64
        let count: Int
        let active: Int
    }

    struct VMDisk {
        let size: Int64
        let used: Int64
        let available: Int64
    }

    private(set) var categories: [Category] = []
    private(set) var vmDisk: VMDisk?
    private(set) var isLoading = false
    private(set) var cleaning: Set<Category.Kind> = []
    var lastError: String?

    var api: DockerAPI?

    var dockerTotal: Int64 { categories.reduce(0) { $0 + $1.total } }
    var reclaimableTotal: Int64 { categories.reduce(0) { $0 + $1.reclaimable } }

    func refresh() async {
        guard let api else { categories = []; return }
        isLoading = true
        defer { isLoading = false }

        struct Usage: Decodable {
            let ActiveCount: Int?
            let TotalCount: Int?
            let TotalSize: Int64?
            let Reclaimable: Int64?
        }
        struct DF: Decodable {
            let ImageUsage: Usage?
            let ContainerUsage: Usage?
            let VolumeUsage: Usage?
            let BuildCacheUsage: Usage?
        }

        async let vm = Self.readVMDisk()
        do {
            let df: DF = try await api.get("/system/df")
            let pairs: [(Category.Kind, Usage?)] = [
                (.images, df.ImageUsage), (.containers, df.ContainerUsage),
                (.volumes, df.VolumeUsage), (.buildCache, df.BuildCacheUsage),
            ]
            categories = pairs.map { kind, usage in
                Category(
                    kind: kind, total: usage?.TotalSize ?? 0, reclaimable: usage?.Reclaimable ?? 0,
                    count: usage?.TotalCount ?? 0, active: usage?.ActiveCount ?? 0
                )
            }
        } catch {
            lastError = message(for: error) ?? lastError
        }
        vmDisk = await vm
    }

    /// Frees the reclaimable space of one category; returns the bytes reclaimed.
    func clean(_ kind: Category.Kind) async -> Int64 {
        guard let api else { return 0 }
        struct Report: Decodable { let SpaceReclaimed: Int64? }
        let path: String = switch kind {
        case .images: "/images/prune?filters=\(#"{"dangling":["false"]}"#.urlEscaped)"
        case .containers: "/containers/prune"
        case .volumes: "/volumes/prune?filters=\(#"{"all":["true"]}"#.urlEscaped)"
        case .buildCache: "/build/prune?all=true"
        }
        cleaning.insert(kind)
        defer { cleaning.remove(kind) }
        do {
            let data = try await api.send("POST", path)
            await refresh()
            return (try? JSONDecoder().decode(Report.self, from: data))?.SpaceReclaimed ?? 0
        } catch {
            lastError = message(for: error) ?? lastError
            return 0
        }
    }

    /// `df` of Docker's data directory inside the Colima VM.
    private static func readVMDisk() async -> VMDisk? {
        guard let data = try? await Shell.run("colima", ["ssh", "--", "df", "-B1", "/var/lib/docker"]) else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: " ")
        guard fields.count >= 4, let size = Int64(fields[1]), let used = Int64(fields[2]), let free = Int64(fields[3]) else {
            return nil
        }
        return VMDisk(size: size, used: used, available: free)
    }
}
