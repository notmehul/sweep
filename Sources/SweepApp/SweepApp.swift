import SweepStore
import SweepSystem
import SwiftUI

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
    }
}
