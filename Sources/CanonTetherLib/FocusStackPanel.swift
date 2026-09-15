import SwiftUI
import CanonTetherCore

/// The focus-stacking sheet: set up a bracket, shoot it, merge it, read the result.
///
/// Presented as a sheet rather than another inspector section because a bracket is *modal* in
/// practice — the camera is unavailable for ordinary shooting while the lens racks, so hiding the
/// normal shutter behind a sheet matches what the hardware is actually doing.
struct FocusStackPanel: View {
    @ObservedObject var model: FocusStackModel
    @ObservedObject var viewModel: CameraViewModel
    /// Closing is the window controller's job — a window has no `presentationMode` to dismiss.
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RangeLiveView(feed: viewModel.liveViewFeed, region: $model.subjectRegion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            Divider()
            controls
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .onAppear { model.enterBracketingMode(liveViewIsOn: viewModel.isLiveViewOn) }
        .onDisappear { model.exitBracketingMode() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Focus Stacking", systemImage: "camera.metering.center.weighted")
                .font(.headline)
            if let capability = model.capability, let problem = capability.explanation {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .lineLimit(2)
            }
            Spacer()
            // Diagnostics live behind a menu: needed when something is wrong, noise the rest of
            // the time. Recording a map is how the scan gets tuned without a camera round trip.
            Menu {
                Button("Record Focus Map…") { model.recordFocusMap() }
                Button("Test Focus Drive…") { model.diagnoseFocusDrive() }
                if model.subjectRegion != nil {
                    Divider()
                    Button("Clear Subject Box") { model.subjectRegion = nil }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isBusy)
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isCapturing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button(action: { model.scanAndShoot() }) {
                    Text(model.isBusy ? "Working…" : "Scan & Shoot Stack")
                        .frame(minWidth: 190)
                }
                .controlSize(.large)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!viewModel.isConnected || model.capability?.isAvailable != true || model.isBusy)

                Button("Autofocus") { model.autofocus() }
                    .controlSize(.large)
                    .help("Focus on the subject before scanning — the sweep is centred on wherever "
                          + "focus sits when it starts")
                    .disabled(!viewModel.isConnected || model.capability?.isAvailable != true || model.isBusy)

                if model.isBusy {
                    Button("Stop") {
                        model.cancelRacking()
                        model.cancelBracket()
                    }
                    .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusLine)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = detailLine {
                        Text(detail).font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if let render = model.lastRender {
                    Button("Reveal") { model.revealRender() }
                }
            }

            if model.isMerging {
                ProgressView(value: model.mergeFraction)
            }

            if let render = model.lastRender, render.framesAreStatic {
                Label("Every frame is the same picture — the lens didn't move. Check the switch on "
                      + "the lens is set to AF.", systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let diagnosis = model.diagnosis {
                Text(diagnosis)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// One line saying what is happening, or what to do next.
    private var statusLine: String {
        if let progress = model.bracketProgress, model.isCapturing { return progress.label }
        if model.isMerging { return model.mergeStatus }
        if model.isRecoveringLiveView { return "Waiting for the camera's live view to come back…" }
        if let scan = model.scanProgress { return scan }
        if let render = model.lastRender { return "Merged — \(render.outputURL.lastPathComponent)" }
        if model.subjectRegion == nil { return "Autofocus on your subject, drag a box around it, then Scan & Shoot." }
        return "Ready — Autofocus first if focus has moved since you drew the box."
    }

    private var detailLine: String? {
        if model.isCapturing || model.isMerging || model.isRacking { return nil }
        if let render = model.lastRender {
            // Every finding, not just the first. A bracket can simultaneously have gaps in the
            // middle and wasted frames at one end, and those call for opposite corrections —
            // showing only one of them sends the photographer the wrong way.
            return render.critique.advice.joined(separator: "  ")
        }
        if model.subjectRegion != nil {
            return "The scan sweeps focus, measures the subject's depth, and shoots the bracket itself."
        }
        return nil
    }
}

private struct RangeLiveView: View {
    @ObservedObject var feed: LiveViewFeed
    /// The subject box, in normalised image coordinates. Drawn by dragging across the preview.
    @Binding var region: FocusDepthMap.Region?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                if let image = feed.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("Waiting for live view…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                subjectOverlay(in: geometry.size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        defer { dragStart = nil; dragCurrent = nil }
                        guard let start = dragStart else { return }
                        region = Self.region(from: start, to: value.location, in: geometry.size)
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func subjectOverlay(in size: CGSize) -> some View {
        if let start = dragStart, let current = dragCurrent {
            box(Self.rect(from: start, to: current))
        } else if let region {
            box(CGRect(x: region.x * size.width, y: region.y * size.height,
                       width: region.width * size.width, height: region.height * size.height))
        }
    }

    private func box(_ rect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(Color.green, lineWidth: 2)
            .background(Rectangle().fill(Color.green.opacity(0.08)))
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Normalises a dragged rectangle. Returns nil for a stray click, so a mis-tap clears nothing
    /// and selects nothing.
    private static func region(from a: CGPoint, to b: CGPoint, in size: CGSize) -> FocusDepthMap.Region? {
        guard size.width > 0, size.height > 0 else { return nil }
        let r = rect(from: a, to: b)
        guard r.width > size.width * 0.05, r.height > size.height * 0.05 else { return nil }
        return FocusDepthMap.Region(x: max(0, r.minX / size.width),
                                    y: max(0, r.minY / size.height),
                                    width: min(1, r.width / size.width),
                                    height: min(1, r.height / size.height))
    }
}
