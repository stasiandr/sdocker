import Foundation
import Observation

struct Network: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let driver: String
    let scope: String
    let subnets: [String]
    let gateways: [String]
    let created: Date?
    let isInternal: Bool
    let project: String?

    var isBuiltIn: Bool { ["bridge", "host", "none"].contains(name) }
}

@MainActor
@Observable
final class NetworksStore {
    private(set) var networks: [Network] = []
    /// Network id → (container name, IP address).
    private(set) var members: [String: [(name: String, ip: String)]] = [:]
    private(set) var isLoading = false
    var lastError: String?

    var api: DockerAPI?

    func refresh() async {
        guard let api else { networks = []; return }
        isLoading = true
        defer { isLoading = false }

        struct NetworkJSON: Decodable {
            let Id: String
            let Name: String
            let Driver: String
            let Scope: String
            let Created: String?
            let Internal: Bool?
            let IPAM: IPAM?
            let Labels: [String: String]?

            struct IPAM: Decodable {
                let Config: [Config]?
                struct Config: Decodable { let Subnet: String?; let Gateway: String? }
            }
        }

        do {
            async let list: [NetworkJSON] = api.get("/networks")
            async let containers: [ContainerSummary] = api.get("/containers/json?all=1")
            var byNetwork: [String: [(String, String)]] = [:]
            for summary in try await containers {
                let name = Container(summary).name
                for (_, endpoint) in summary.NetworkSettings?.Networks ?? [:] {
                    if let id = endpoint.NetworkID { byNetwork[id, default: []].append((name, endpoint.IPAddress ?? "")) }
                }
            }
            members = byNetwork
            networks = try await list.map { n in
                Network(
                    id: n.Id, name: n.Name, driver: n.Driver, scope: n.Scope,
                    subnets: n.IPAM?.Config?.compactMap(\.Subnet) ?? [],
                    gateways: n.IPAM?.Config?.compactMap(\.Gateway) ?? [],
                    created: ISO8601DateFormatter.parse(n.Created), isInternal: n.Internal ?? false,
                    project: n.Labels?["com.docker.compose.project"]
                )
            }
            .sorted { ($0.isBuiltIn ? 0 : 1, $0.name) < ($1.isBuiltIn ? 0 : 1, $1.name) }
        } catch {
            lastError = message(for: error) ?? lastError
        }
    }

    func create(name: String, subnet: String, gateway: String, isInternal: Bool) async throws {
        guard let api else { return }
        struct Body: Encodable {
            let Name: String
            let Driver = "bridge"
            let Internal: Bool
            let IPAM: IPAM?
            struct IPAM: Encodable { let Config: [[String: String]] }
        }
        var config: [String: String] = [:]
        if !subnet.isEmpty { config["Subnet"] = subnet }
        if !gateway.isEmpty { config["Gateway"] = gateway }
        try await api.send("POST", "/networks/create", json: Body(
            Name: name.trimmingCharacters(in: .whitespaces), Internal: isInternal,
            IPAM: config.isEmpty ? nil : .init(Config: [config])
        ))
        await refresh()
    }

    func remove(_ ids: [String]) async {
        guard let api else { return }
        for id in ids {
            do {
                try await api.send("DELETE", "/networks/\(id)")
            } catch {
                lastError = message(for: error) ?? lastError
            }
        }
        await refresh()
    }

    /// Removes custom networks no container uses; returns their names.
    func pruneUnused() async -> [String] {
        guard let api else { return [] }
        struct Report: Decodable { let NetworksDeleted: [String]? }
        do {
            let data = try await api.send("POST", "/networks/prune")
            await refresh()
            return (try? JSONDecoder().decode(Report.self, from: data))?.NetworksDeleted ?? []
        } catch {
            lastError = message(for: error) ?? lastError
            return []
        }
    }
}
