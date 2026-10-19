import AppKit
import SweepCore
import SwiftUI

struct BucketScreen: View {
    var model: AppModel
    var bucket: Bucket
    @ViewState private var focused: Finding.ID?

    private var findings: [Finding] { model.visibleFindings(in: bucket) }
    private var groups: [(String, [Finding])] {
        Dictionary(grouping: findings, by: \.group)
            .map { ($0.key, $0.value.sorted { $0.reclaimableSize > $1.reclaimableSize }) }
            .sorted { $0.1.reduce(0) { $0 + $1.reclaimableSize } > $1.1.reduce(0) { $0 + $1.reclaimableSize } }
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
        .onAppear { focused = findings.first?.id }
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
                if findings.isEmpty {
                    Text("Nothing here. Your Mac is tidy in this area.")
                        .font(Theme.body).foregroundStyle(Theme.secondary).padding(28)
                }
                ForEach(groups, id: \.0) { group, items in
                    Section {
                        ForEach(items) { finding in
                            FindingRow(finding: finding,
                                       selectable: bucket != .yours,
                                       selected: model.selection.contains(finding.id),
                                       focused: focused == finding.id,
                                       toggle: { model.toggle(finding) },
                                       focus: { focused = finding.id })
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
        if let finding = findings.first(where: { $0.id == focused }) {
            FindingInspector(finding: finding, keep: {
                model.keep(finding)
                focused = findings.first?.id
            })
            .id(finding.id)
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    private var footer: some View {
        HStack {
            let selectedHere = findings.filter { model.selection.contains($0.id) }
            Text(bucket == .yours
                 ? "Sweep only shows these. Open them in Finder to decide."
                 : "\(selectedHere.count) of \(findings.count) selected here")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
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
}

struct FindingRow: View {
    var finding: Finding
    var selectable: Bool
    var selected: Bool
    var focused: Bool
    var toggle: () -> Void
    var focus: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if selectable {
                Toggle("", isOn: Binding(get: { selected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select \(finding.title)")
            }
            FileIcon(path: finding.items.first?.path ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(Format.relative(finding.lastUsed?.date))
                    .font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Text(Format.bytes(finding.reclaimableSize)).font(Theme.rowNumber).foregroundStyle(Theme.text)
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
    var finding: Finding
    var keep: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    FileIcon(path: finding.items.first?.path ?? "", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title).font(Theme.headline).foregroundStyle(Theme.text)
                        Text(Format.bytes(finding.reclaimableSize)).font(Theme.number).foregroundStyle(Theme.secondary)
                    }
                }
                answer("What it is", finding.explanation.whatItIs).padding(.top, 22)
                answer("If you remove it", finding.explanation.ifRemoved)
                answer("Why Sweep flagged it", finding.explanation.whyStale)

                if let path = finding.items.first?.path {
                    Text(path)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                    HStack(spacing: 4) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Self.expand(path))])
                        }
                        Button("Keep, don't ask again", action: keep)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .padding(.top, 8)
                    .padding(.leading, -14)
                }
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
