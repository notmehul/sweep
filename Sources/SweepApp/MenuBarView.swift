import AppKit
import SwiftUI

struct MenuBarView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text("Sweep")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.text)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Free space")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Text(model.freeSpace.map(Format.bytes) ?? "Checking…")
                    .font(Theme.title)
                    .foregroundStyle(Theme.text)
                Text("Last scan: \(Format.ago(model.lastScanDate))")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack(spacing: 6) {
                Button("Open Sweep", action: openSweep)
                    .quietButton()
                    .fixedSize()
                    .padding(.leading, -14)
                Spacer(minLength: 0)
                Button("Scan now") {
                    model.startScan()
                    openSweep()
                }
                .primaryButton()
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear { model.refreshMenuBar() }
    }

    private func openSweep() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
