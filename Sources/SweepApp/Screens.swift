import AppKit
import SweepCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Group {
                switch model.screen {
                case .welcome: WelcomeScreen(model: model)
                case .scanning: ScanScreen(model: model)
                case .results: ResultsScreen(model: model)
                case .bucket(let bucket): BucketScreen(model: model, bucket: bucket)
                case .cleaning: CleaningScreen()
                case .done: DoneScreen(model: model)
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
        }
        .animation(.easeOut(duration: 0.28), value: model.screen)
        .sheet(isPresented: $model.confirming) { ConfirmSheet(model: model) }
        .frame(minWidth: 940, minHeight: 620)
        .preferredColorScheme(Self.forcedScheme)
        .onAppear {
            // Dev aid: SWEEP_AUTOSCAN=1 starts a scan on launch, for screenshots without focus.
            if ProcessInfo.processInfo.environment["SWEEP_AUTOSCAN"] == "1", model.screen == .welcome { model.startScan() }
        }
    }

    /// Dev aid: `SWEEP_APPEARANCE=light|dark` pins the appearance for screenshots.
    private static let forcedScheme: ColorScheme? = switch ProcessInfo.processInfo.environment["SWEEP_APPEARANCE"] {
        case "light": .light
        case "dark": .dark
        default: nil
    }
}

// MARK: - Welcome

struct WelcomeScreen: View {
    var model: AppModel
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 56) {
            SunburstView(segments: SunburstLayout.segments(for: DemoSource.tree), progress: nil,
                         centerTitle: "", centerSubtitle: "", hovered: .constant(nil))
                .frame(width: 360, height: 360)
                .opacity(0.22)
                .saturation(0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text("See what's filling up your Mac.")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Sweep looks through your files, explains what it finds in plain words, and asks before removing anything. Nothing leaves your Mac.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                AccessRow(granted: model.hasFullDiskAccess)
                    .padding(.top, 32)

                HStack(spacing: 12) {
                    Button("Start scan") { model.startScan() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    if !model.hasFullDiskAccess {
                        Text("You can also scan without it.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.top, 24)
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(poll) { _ in model.refreshAccess() }
    }
}

struct AccessRow: View {
    var granted: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.shield" : "lock.shield")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(granted ? Theme.accent : Theme.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Full Disk Access").font(Theme.headline).foregroundStyle(Theme.text)
                Text(granted ? "Sweep can see app data in your Library."
                             : "Lets Sweep see app data in your Library. Without it, some folders stay hidden.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(16)
        .card()
        .animation(.easeOut(duration: 0.2), value: granted)
    }
}

// MARK: - Scanning

struct ScanScreen: View {
    var model: AppModel
    @ViewState private var hovered: SunburstSegment?

    var body: some View {
        let progress = model.progress
        let fraction = progress?.fraction ?? 0
        HStack(spacing: 64) {
            SunburstView(
                segments: model.liveTree.map { SunburstLayout.segments(for: $0, total: progress?.totalBytes) } ?? [],
                progress: fraction, showsBeam: true,
                centerTitle: "Scanning", centerSubtitle: Format.bytes(progress?.scannedBytes ?? 0),
                hovered: $hovered)
                .frame(width: 420, height: 420)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int((fraction * 100).rounded()))").font(Theme.display)
                    Text("%").font(Theme.displayUnit).foregroundStyle(Theme.secondary)
                }
                .foregroundStyle(Theme.text)

                Text(progress.map { p in p.currentPath.hasPrefix("~") || p.currentPath.hasPrefix("/")
                                       ? "Looking in " + p.currentPath : p.currentPath + "…" } ?? "Getting ready…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 4)

                VStack(spacing: 0) {
                    StatRow(label: "Checked", value: progress.map { Format.bytes($0.scannedBytes) } ?? "–")
                    StatRow(label: "Files", value: progress.map { Format.count($0.filesSeen) } ?? "–")
                }
                .padding(.top, 28)

                Button("Cancel") { model.cancelScan() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 28)
                    .padding(.leading, -14)
            }
            .frame(width: 300, alignment: .leading)
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scanning, \(Int(fraction * 100)) percent")
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value).foregroundStyle(Theme.text)
        }
        .font(Theme.number)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

// MARK: - Results

struct ResultsScreen: View {
    var model: AppModel
    @ViewState private var hovered: SunburstSegment?

    var body: some View {
        if let report = model.report {
            HStack(spacing: 56) {
                SunburstView(segments: SunburstLayout.segments(for: report.tree), progress: nil,
                             centerTitle: "Your Mac", centerSubtitle: Format.bytes(report.tree.allocatedSize),
                             hovered: $hovered)
                    .frame(width: 400, height: 400)

                VStack(alignment: .leading, spacing: 0) {
                    Text("You can free").font(Theme.body).foregroundStyle(Theme.secondary)
                    let parts = Format.bytesParts(model.freeable)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(parts.0).font(Theme.display)
                        Text(parts.1).font(Theme.displayUnit).foregroundStyle(Theme.secondary)
                    }
                    .foregroundStyle(Theme.text)
                    Text(report.summary)
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    if let changes = report.changes {
                        Label(changes, systemImage: "clock.arrow.circlepath")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }

                    VStack(spacing: 0) {
                        ForEach([Bucket.rebuilds, .review, .yours], id: \.self) { bucket in
                            BucketRow(bucket: bucket, size: model.total(of: bucket),
                                      count: FindingRowModel.rows(for: model.visibleFindings(in: bucket)).count) {
                                model.screen = .bucket(bucket)
                            }
                            if bucket != .yours { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 56) }
                        }
                    }
                    .card()
                    .padding(.top, 24)

                    if report.coverage < 0.99 {
                        Label("Some app folders were hidden from Sweep. Allow Full Disk Access to see everything.",
                              systemImage: "eye.slash")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .padding(.top, 12)
                    }

                    HStack(spacing: 8) {
                        Button("Scan again") { model.startScan() }
                            .buttonStyle(QuietButtonStyle())
                        Spacer()
                        Button(model.selectedBytes > 0 ? "Free \(Format.bytes(model.selectedBytes))…" : "Nothing selected") {
                            model.confirming = true
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.selectedBytes == 0)
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 24)
                }
                .frame(maxWidth: 460)
            }
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct BucketRow: View {
    var bucket: Bucket
    var size: Int64
    var count: Int
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                BucketBadge(bucket: bucket)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Theme.title(for: bucket)).font(Theme.headline).foregroundStyle(Theme.text)
                    Text("\(Theme.blurb(for: bucket)) · \(count)")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Format.bytes(size)).font(Theme.rowNumber).foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.hairline.opacity(hovering ? 0.6 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("\(Theme.title(for: bucket)), \(Format.bytes(size)), \(count) items")
    }
}

struct BucketBadge: View {
    var bucket: Bucket
    var body: some View {
        Image(systemName: Theme.symbol(for: bucket))
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.color(for: bucket))
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.color(for: bucket).opacity(0.14)))
            .accessibilityHidden(true)
    }
}
