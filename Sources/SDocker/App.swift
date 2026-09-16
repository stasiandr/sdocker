import AppKit
import SwiftUI

@main
struct SDockerApp: App {
    @State private var engine = EngineStore()
    @State private var containers = ContainersStore()
    @State private var images = ImagesStore()
    @State private var volumes = VolumesStore()
    @State private var networks = NetworksStore()
    @State private var builds = BuildsStore()
    @State private var disk = DiskStore()
    /// `-section builds` opens on a section, for scripted screenshots.
    @State private var section = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "section")?.capitalized ?? "") ?? .containers
    @State private var newBuild: BuildRequest?
    @State private var runPrefill: RunPrefill?

    var body: some Scene {
        Window("sdocker", id: "main") {
            ContentView(section: $section, newBuild: $newBuild, runPrefill: $runPrefill)
                .environment(engine)
                .environment(containers)
                .environment(images)
                .environment(volumes)
                .environment(networks)
                .environment(builds)
                .environment(disk)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Run Container…") {
                    section = .containers
                    runPrefill = RunPrefill()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!engine.isRunning)
                Button("Pull Image…") {
                    section = .images
                    NotificationCenter.default.post(name: .pullImage, object: nil)
                }
                .keyboardShortcut("n")
                .disabled(!engine.isRunning)
                Button("New Build…") {
                    section = .builds
                    newBuild = .blank
                }
                .keyboardShortcut("b")
                .disabled(!engine.isRunning)
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    Button(item.rawValue) { section = item }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Divider()
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case containers = "Containers"
    case images = "Images"
    case volumes = "Volumes"
    case networks = "Networks"
    case builds = "Builds"
    case engine = "Engine"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .containers: "square.stack.3d.up"
        case .images: "shippingbox"
        case .volumes: "externaldrive"
        case .networks: "network"
        case .builds: "hammer"
        case .engine: "cpu"
        }
    }
}

extension Notification.Name {
    static let pullImage = Notification.Name("sdocker.pullImage")
    /// Posted with an image reference to open the run sheet for it.
    static let runImage = Notification.Name("sdocker.runImage")
}
