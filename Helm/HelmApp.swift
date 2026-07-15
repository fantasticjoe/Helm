import SwiftUI

struct HelmApp: App {
    @State private var engine: MonitorEngine

    init() {
        let engine = MonitorEngine.shared
        engine.start()
        _engine = State(initialValue: engine)
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
                .environment(engine)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 1000, height: 640)

        MenuBarExtra {
            MenuBarView()
                .environment(engine)
        } label: {
            Image(systemName: "helm")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
