import SweepStore
import SwiftUI

struct HistoryScreen: View {
    var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(spacing: 12) {
                    if model.isLoadingHistory && model.cleanups.isEmpty {
                        ProgressView()
                            .controlSize(.large)
                            .padding(Theme.gutter)
                    } else if model.cleanups.isEmpty {
                        Text("Nothing cleaned yet.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 28)
                    } else {
                        ForEach(model.cleanups) { cleanup in
                            CleanupHistoryRow(
                                cleanup: cleanup,
                                isUndoing: model.historyUndoing.contains(cleanup.id),
                                undo: { model.undo(cleanupID: cleanup.id) }
                            )
                        }
                    }

                    if let message = model.historyMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.screen = .results
            } label: {
                Label("Results", systemImage: "chevron.left")
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(.cancelAction)
            .padding(.leading, -8)

            Text("History")
                .font(Theme.title)
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 16)
    }
}

private struct CleanupHistoryRow: View {
    var cleanup: CleanupRecord
    var isUndoing: Bool
    var undo: () -> Void

    private var deletedCount: Int {
        cleanup.entries.filter { $0.action != "trash" }.count
    }

    private var trashedCount: Int {
        cleanup.entries.filter { $0.action == "trash" }.count
    }

    private var canUndo: Bool {
        cleanup.entries.contains { $0.action == "trash" && $0.trashURL != nil && !$0.undone }
    }

    private var totalBytes: Int64 {
        cleanup.entries.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Format.cleanupDate(cleanup.date))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Text(summary)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
            }
            Spacer(minLength: 12)
            Text(Format.bytes(totalBytes))
                .font(Theme.rowNumber)
                .foregroundStyle(Theme.text)
            if canUndo {
                Button(isUndoing ? "Putting back…" : "Put back from Trash", action: undo)
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isUndoing)
            }
        }
        .padding(16)
        .card()
    }

    private var summary: String {
        var parts: [String] = []
        if deletedCount > 0 {
            parts.append("Deleted \(deletedCount) \(deletedCount == 1 ? "item" : "items")")
        }
        if trashedCount > 0 {
            parts.append("Moved \(trashedCount) to Trash")
        }
        return parts.joined(separator: " · ")
    }
}
