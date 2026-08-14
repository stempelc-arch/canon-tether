import SwiftUI
import CanonTetherCore

/// The right-hand column: camera settings on top, scopes underneath.
///
/// Laid out as iOS-style inset grouped cards — a labelled section, rounded card, full-width rows
/// with hairline separators — because that shape suits a narrow column of one-line settings far
/// better than a dense Mac form does. The controls inside stay native, though: real pop-up menus,
/// system materials and semantic colours, so it still behaves like a Mac app in either appearance.
struct InspectorPanel: View {
    @ObservedObject var viewModel: CameraViewModel
    @ObservedObject var analysis: ShotAnalysisStore
    /// The shot the main viewer is showing — what the scopes and the focus/exposure readout measure.
    let previewURL: URL?

    private var exposureSettings: [CameraSetting] {
        ExposureGrid.exposurePaths.compactMap { path in
            viewModel.settings.first { $0.path == path }
        }
    }

    private var otherSettings: [CameraSetting] {
        viewModel.settings.filter { !ExposureGrid.exposurePaths.contains($0.path) }
    }

    var body: some View {
        // Measured rather than fixed so the scopes grow with the column: widen the window or drag
        // the split-view divider and the vectorscope gets bigger with it.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 14)

                // Settings scroll; the scopes (and the focus/exposure readout above them) stay pinned
                // to the bottom of the column so they're always on screen — a live read on the shot,
                // not something to scroll to.
                settingsList

                Divider()

                QualityReadout(focus: previewURL.flatMap { analysis.focus[$0] },
                               exposure: previewURL.flatMap { analysis.exposure[$0] },
                               highlightClipLimit: ShotAnalysisStore.exposureHighlightClipLimit,
                               shadowClipLimit: ShotAnalysisStore.exposureShadowClipLimit,
                               nearWhiteLimit: ShotAnalysisStore.exposureNearWhiteLimit)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                ScopesPanel(url: previewURL, layout: ScopeLayout(available: geometry.size))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .task(id: previewURL) {
                if let previewURL { analysis.analyze(previewURL) }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var settingsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if viewModel.settings.isEmpty {
                    connectingCard
                } else {
                    SettingsSection {
                        rows(exposureSettings + otherSettings, steppers: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Camera Settings")
                .font(.system(size: 19, weight: .bold))
            Spacer(minLength: 4)
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(viewModel.isConnected ? "Live" : "Offline")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rows(_ settings: [CameraSetting], steppers: Bool) -> some View {
        ForEach(settings) { setting in
            SettingRow(
                setting: setting,
                isBusy: viewModel.isBusy,
                showsStepper: steppers && ExposureGrid.exposurePaths.contains(setting.path)
            ) { newValue in
                viewModel.updateSetting(setting, to: newValue)
            }
            if setting.id != settings.last?.id {
                Divider().padding(.leading, 14)
            }
        }
    }

    // No spinner and no "Connecting…" wording here: the header's Live/Offline dot already
    // states the connection, and the capture column's ReconnectBanner already owns the live
    // wait/connect status text — repeating either just adds another "waiting for camera" message.
    private var connectingCard: some View {
        SectionCard {
            HStack(spacing: 9) {
                Text(viewModel.isConnected ? "No adjustable settings reported." : "Settings will appear once connected.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
        }
    }
}

// MARK: - Focus / exposure readout

/// A one-line focus + exposure read pinned just above the scopes — the same shot the scopes measure.
/// Spelled out and colour-coded: the focus confidence in its verdict colour (green / amber / red),
/// and the exposure state as green "OK", or the clipped end(s) — "Highlights" / "Shadows" — in red
/// when data is being lost ("Bright" / "Dark" cover the rare mis-exposure that avoids hard clipping).
/// Each side appears only once its shot has been analysed.
private struct QualityReadout: View {
    let focus: FocusResult?
    let exposure: ExposureResult?
    let highlightClipLimit: Double
    let shadowClipLimit: Double
    let nearWhiteLimit: Double

    var body: some View {
        HStack(spacing: 10) {
            if let focus { focusView(focus) }
            Spacer(minLength: 8)
            if let exposure { exposureView(exposure) }
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func focusView(_ f: FocusResult) -> some View {
        let tint: Color = f.verdict == .sharp ? .green : (f.verdict == .borderline ? .yellow : .red)
        return HStack(spacing: 5) {
            Text("Focus").foregroundStyle(.secondary)
            Text("\(f.score)%").foregroundStyle(tint)
        }
        .help("Focus confidence — \(f.verdict.label). A sharpness estimate of the in-focus region, not a guarantee.")
    }

    private func exposureView(_ e: ExposureResult) -> some View {
        // Recompute which ends clip against the live tolerance so the words track the current limits.
        let hi = e.highlightClip > highlightClipLimit || e.nearWhite > nearWhiteLimit
        let lo = e.shadowClip > shadowClipLimit
        return HStack(spacing: 5) {
            Text("Exposure").foregroundStyle(.secondary)
            exposureStatus(e, hi: hi, lo: lo)
        }
        .help(ExposureExplanation.text(for: e, highlightClipLimit: highlightClipLimit,
                                        shadowClipLimit: shadowClipLimit, nearWhiteLimit: nearWhiteLimit))
    }

    @ViewBuilder
    private func exposureStatus(_ e: ExposureResult, hi: Bool, lo: Bool) -> some View {
        if hi || lo {
            HStack(spacing: 5) {
                if hi { Text("Highlights").foregroundStyle(.red) }
                if lo { Text("Shadows").foregroundStyle(.red) }
            }
        } else {
            switch e.verdict {
            case .good: Text("OK").foregroundStyle(.green)
            case .over: Text("Bright").foregroundStyle(.red)   // median high without hard clipping
            case .under: Text("Dark").foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Grouped card chrome

/// A labelled group: small caption above, rounded card below, optional footnote underneath — the
/// inset-grouped list shape, built out of Mac semantic colours.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                SectionLabel(title)
                    .padding(.horizontal, 4)
            }

            SectionCard { VStack(spacing: 0) { content() } }

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// The small caption that names a group.
struct SectionLabel: View {
    private let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

/// The card itself: raised surface, continuous corners, hairline edge.
struct SectionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - Rows

struct SettingRow: View {
    let setting: CameraSetting
    let isBusy: Bool
    let showsStepper: Bool
    let onChange: (String) -> Void

    /// Reserved on every row of a section that has steppers, so those values stay in one column
    /// even when a row (a read-only one, say) has no buttons of its own. Sections without steppers
    /// don't reserve it — that width is worth more to a long value like "RAW + Large Fine JPEG".
    private static let stepperWidth: CGFloat = 52

    private var isSteppable: Bool { !setting.readOnly && !setting.choices.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Text(setting.label)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(1)
                .help(setting.label)

            Spacer(minLength: 8)

            value

            if showsStepper {
                if isSteppable {
                    ExposureStepper(setting: setting, isBusy: isBusy, onChange: onChange)
                        .frame(width: Self.stepperWidth, alignment: .trailing)
                } else {
                    Spacer().frame(width: Self.stepperWidth)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }

    @ViewBuilder
    private var value: some View {
        if setting.readOnly || setting.choices.isEmpty {
            valueText(rowLabel(setting.current))
                .foregroundStyle(.secondary)
                .help(displayLabel(setting.current))
        } else {
            Menu {
                // Label may be transformed (e.g. "cM1 + cS3" → readable format names) while the
                // value passed back stays the raw one `set-config` expects.
                ForEach(menuChoices, id: \.self) { choice in
                    Button {
                        onChange(choice)
                    } label: {
                        if choice == setting.current {
                            Label(displayLabel(choice), systemImage: "checkmark")
                        } else {
                            Text(displayLabel(choice))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    valueText(rowLabel(setting.current))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // Sized to its content so every value sits flush right, against the steppers. A
            // borderless menu ignores alignment inside its own label, so this is what right-aligns
            // the column; the cost is that the longest RAW+JPEG combinations can nibble the
            // setting's name at the narrowest panel width, which the tooltip covers.
            .fixedSize()
            .disabled(isBusy)
            .help(displayLabel(setting.current))
        }
    }

    /// Values read as numbers on a camera back, so they get the same rounded, tabular treatment.
    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var menuChoices: [String] {
        SettingDisplay.choices(setting.choices, path: setting.path, current: setting.current)
    }

    /// What the row shows for the current value. A `fixedSize` menu is rigid, so an unbounded value
    /// would set a floor on how narrow the whole column can get — and the split-view divider stops
    /// where that floor is. Capping the row (the menu itself still lists every value in full, and
    /// the tooltip has it) keeps the panel draggable down to its minimum width.
    private func rowLabel(_ value: String) -> String {
        let text = displayLabel(value)
        guard text.count > 24 else { return text }
        return text.prefix(11) + "…" + text.suffix(11)
    }

    private func displayLabel(_ value: String) -> String {
        SettingDisplay.label(forValue: value, path: setting.path)
    }
}

/// Nudge buttons for the three exposure settings, as one segmented pill. "−" and "+" mean less and
/// more *light*, the same sense they have on the camera's own exposure compensation — so one press
/// of "+" is a step brighter whichever row it's on, even though that means a lower f-number and a
/// slower shutter.
private struct ExposureStepper: View {
    let setting: CameraSetting
    let isBusy: Bool
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", brighter: false, help: "One step darker")
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 13)
            button("plus", brighter: true, help: "One step brighter")
        }
        .background(Color.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func button(_ symbol: String, brighter: Bool, help: String) -> some View {
        // Nil at the end of the camera's range, which disables the button rather than wrapping around.
        let target = ExposureGrid.neighbor(
            of: setting.current,
            in: setting.choices,
            path: setting.path,
            brighter: brighter
        )
        let enabled = !isBusy && target != nil
        return Button {
            if let target { onChange(target) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
