import AppKit
import SweepStore
import SweepSystem
import SwiftUI
import UniformTypeIdentifiers

@main
struct SweepApp: App {
    @ViewState private var model = SweepApp.makeModel()

    /// `SWEEP_DEMO=1` replays sample data; otherwise the real engine runs.
    private static func makeModel() -> AppModel {
        let probe: @Sendable () -> Bool = { FDAProbe.hasFullDiskAccess() }
        if ProcessInfo.processInfo.environment["SWEEP_DEMO"] == "1" {
            return AppModel(source: DemoSource(), cleaner: DemoCleaner(), accessProbe: probe)
        }
        let store = try? Store()
        return AppModel(source: EngineScanSource(store: store), cleaner: EngineCleaner(store: store), accessProbe: probe)
    }

    var body: some Scene {
        Window("Sweep", id: "main") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .help) {
                Button("Export Scan Report…") {
                    exportScanReport()
                }
                .disabled(model.report == nil)
            }
        }

        MenuBarExtra("Sweep", systemImage: "circle.dashed") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    private func exportScanReport() {
        do {
            let data = try model.scanReportData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "Sweep Scan Report.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Sweep couldn't export the scan report."
            alert.informativeText = "Choose another location and try again."
            alert.runModal()
        }
    }
}
