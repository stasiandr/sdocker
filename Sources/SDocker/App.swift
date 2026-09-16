import AppKit
import SwiftUI

@main
struct SDockerApp: App {
    @State private var engine = EngineStore()
    @State private var images = ImagesStore()
    @State private var builds = BuildsStore()
    /// `-section builds` opens on a section, for scripted screenshots.
    @State private var section = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "section")?.capitalized ?? "") ?? .images
    @State private var newBuild: BuildRequest?

    var body: some Scene {
        Window("sdocker", id: "main") {
            ContentView(section: $section, newBuild: $newBuild)
                .environment(engine)
                .environment(images)
                .environment(builds)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Pull Image…") {
                    section = .images
                    NotificationCenter.default.post(name: .pullImage, object: nil)
                }
                .keyboardShortcut("n")
                Button("New Build…") {
                    section = .builds
                    newBuild = .blank
                }
                .keyboardShortcut("b")
                .disabled(!engine.isRunning)
            }
            CommandGroup(after: .sidebar) {
                Button("Images") { section = .images }.keyboardShortcut("1")
                Button("Builds") { section = .builds }.keyboardShortcut("2")
                Divider()
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case images = "Images"
    case builds = "Builds"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .images: "shippingbox"
        case .builds: "hammer"
        }
    }
}

extension Notification.Name {
    static let pullImage = Notification.Name("sdocker.pullImage")
}
