import SweepSystem
import SwiftUI

@main
struct SweepApp: App {
    @ViewState private var model = AppModel(source: DemoSource(), cleaner: DemoCleaner(),
                                        accessProbe: { FDAProbe.hasFullDiskAccess() })

    var body: some Scene {
        Window("Sweep", id: "main") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 700)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
    }
}
