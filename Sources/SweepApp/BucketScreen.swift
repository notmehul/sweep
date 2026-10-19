import AppKit
import SweepCore
import SwiftUI

/// One line in the list. Findings with the same title (an app's several cache folders,
/// say) collapse into one row, so people choose per app rather than per folder.
struct FindingRowModel: Identifiable {
    let id: String
    let group: String
    let findings: [Finding]

    var title: String { findings[0].title }
    var size: Int64 { findings.reduce(0) { $0 + $1.reclaimableSize } }
    var lastUsed: Date? { findings.compactMap(\.lastUsed?.date).max() }
    var paths: [String] { findings.flatMap { $0.items.map(\.path) } }

    static func rows(for findings: [Finding]) -> [FindingRowModel] {
        Dictionary(grouping: findings) { "\($0.group)\u{1F}\($0.title)" }
            .map { FindingRowModel(id: $0.key, group: $0.value[0].group, findings: $0.value) }
    }
}

struct BucketScreen: View {
    var model: AppModel
    var bucket: Bucket
    @ViewState private var focused: FindingRowModel.ID?

    private var rows: [FindingRowModel] { FindingRowModel.rows(for: model.visibleFindings(in: bucket)) }
    private var groups: [(String, [FindingRowModel])] {
        Dictionary(grouping: rows, by: \.group)
            .map { ($0.key, $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.1.reduce(0) { $0 + $1.size } > $1.1.reduce(0) { $0 + $1.size } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                list
                Rectangle().fill(Theme.hairline).frame(width: 1)
                inspector.frame(width: 340)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .onAppear { focused = groups.first?.1.first?.id }
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

            BucketBadge(bucket: bucket)
            VStack(alignment: .leading, spacing: 2) {
                Text(Theme.title(for: bucket)).font(Theme.title).foregroundStyle(Theme.text)
                Text(Theme.blurb(for: bucket)).font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Text(Format.bytes(model.total(of: bucket))).font(.system(size: 22, weight: .light).monospacedDigit())
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 16)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if rows.isEmpty {
                    Text("Nothing here. Your Mac is tidy in this area.")
                        .font(Theme.body).foregroundStyle(Theme.secondary).padding(28)
                }
                ForEach(groups, id: \.0) { group, items in
                    Section {
                        ForEach(items) { row in
                            FindingRow(row: row,
                                       selectable: bucket != .yours,
                                       selection: selectionState(row),
                                       focused: focused == row.id,
                                       toggle: { toggle(row) },
                                       focus: { focused = row.id })
                        }
                    } header: {
                        Text(group)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 28)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                            .background(Theme.background)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var inspector: some View {
        if let row = rows.first(where: { $0.id == focused }) {
            FindingInspector(row: row, keep: {
                row.findings.forEach(model.keep)
                focused = rows.first?.id
            })
            .id(row.id)
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack {
            let selectedHere = rows.filter { selectionState(row: $0) != .off }
            Text(bucket == .yours
                 ? "Sweep only shows these. Open them in Finder to decide."
                 : "\(selectedHere.count) of \(rows.count) selected here")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            if bucket != .yours && !rows.isEmpty {
                let allOn = selectedHere.count == rows.count
                Button(allOn ? "Select none" : "Select all") {
                    for row in rows {
                        for finding in row.findings {
                            if allOn { model.selection.remove(finding.id) } else { model.selection.insert(finding.id) }
                        }
                    }
                }
                .buttonStyle(QuietButtonStyle())
            }
            Spacer()
            Button(model.selectedBytes > 0 ? "Free \(Format.bytes(model.selectedBytes))…" : "Nothing selected") {
                model.confirming = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.selectedBytes == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private func selectionState(_ row: FindingRowModel) -> SelectionState { selectionState(row: row) }

    private func selectionState(row: FindingRowModel) -> SelectionState {
        let picked = row.findings.filter { model.selection.contains($0.id) }.count
        return picked == 0 ? .off : (picked == row.findings.count ? .on : .mixed)
    }

    private func toggle(_ row: FindingRowModel) {
        let select = selectionState(row: row) != .on
        for finding in row.findings {
            if select { model.selection.insert(finding.id) } else { model.selection.remove(finding.id) }
        }
    }
}

enum SelectionState { case on, off, mixed }

struct FindingRow: View {
    var row: FindingRowModel
    var selectable: Bool
    var selection: SelectionState
    var focused: Bool
    var toggle: () -> Void
    var focus: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if selectable {
                Toggle("", isOn: Binding(get: { selection == .on }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select \(row.title)")
            }
            FileIcon(path: row.paths.first ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(row.findings.count > 1 ? "\(row.findings.count) folders · \(Format.relative(row.lastUsed))"
                                            : Format.relative(row.lastUsed))
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(row.size)).font(Theme.rowNumber).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .background(focused ? Theme.hairline : (hovering ? Theme.hairline.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(focused ? .isSelected : [])
    }
}

struct FindingInspector: View {
    var row: FindingRowModel
    var keep: () -> Void

    var body: some View {
        let finding = row.findings[0]
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    FileIcon(path: row.paths.first ?? "", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(Theme.headline).foregroundStyle(Theme.text)
                        Text(Format.bytes(row.size)).font(Theme.number).foregroundStyle(Theme.secondary)
                    }
                }
                answer("What it is", finding.explanation.whatItIs).padding(.top, 22)
                answer("If you remove it", finding.explanation.ifRemoved)
                answer("Why Sweep flagged it", row.findings.count > 1
                       ? "\(row.findings.count) folders together use \(Format.bytes(row.size))."
                       : finding.explanation.whyStale)

                ForEach(row.paths.prefix(3), id: \.self) { path in
                    Text(Format.tilde(path))
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                if row.paths.count > 3 {
                    Text("and \(row.paths.count - 3) more")
                        .font(Theme.caption).foregroundStyle(Theme.secondary).padding(.top, 4)
                }
                HStack(spacing: 4) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(row.paths.prefix(10).map { URL(fileURLWithPath: Self.expand($0)) })
                    }
                    Button("Keep, don't ask again", action: keep)
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.top, 8)
                .padding(.leading, -14)
            }
            .padding(24)
        }
    }

    private func answer(_ question: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            Text(text).font(Theme.body).foregroundStyle(Theme.text).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 16)
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

struct FileIcon: View {
    var path: String
    var size: CGFloat = 28
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: FindingInspector.expand(path)))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
