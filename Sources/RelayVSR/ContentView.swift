import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    private let accent = Color(red: 0.42, green: 0.86, blue: 1.0)
    private let violet = Color(red: 0.71, green: 0.42, blue: 1.0)

    var body: some View {
        // The window takes the content's own height. The gradient is a background, so it
        // never adds space of its own.
        VStack(alignment: .leading, spacing: 16) {
            header
            videoCard
            scaleCard
            modelsCard
            actionArea
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.24), Color(red: 0.04, green: 0.04, blue: 0.09)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .background(FixedWindow())
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RelayVSR")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Upscale a video ×2 or ×4 with RelayVSR. Built using Comfy engine.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var videoCard: some View {
        Card(title: "Video") {
            if let url = model.videoURL {
                HStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.title2)
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(videoDetails(url))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Button("Change…") { model.chooseVideo() }
                        .disabled(model.isBusy)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26))
                        .foregroundStyle(dropTargeted ? accent : .white.opacity(0.5))
                    Text("Drop a video here")
                        .font(.headline)
                    Button("Choose Video…") { model.chooseVideo() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTargeted ? accent : .clear, lineWidth: 2)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private var scaleCard: some View {
        Card(title: "Upscale factor") {
            Picker("Upscale factor", selection: $model.scale) {
                ForEach(Scale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy)
        }
    }

    private var modelsCard: some View {
        Card(title: "Model files") {
            // Fixed height, so the box stays the same size whether or not the download button shows.
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.modelsFolder?.path ?? "No folder chosen")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(model.modelsFolder == nil ? .white.opacity(0.5) : .white)
                    Text(modelStatus)
                        .font(.caption)
                        .foregroundStyle(model.missingModels.isEmpty && model.modelsFolder != nil ? accent : .white.opacity(0.6))
                }
                Spacer()
                VStack(spacing: 6) {
                    if model.modelsFolder != nil && !model.missingModels.isEmpty {
                        Button("Download models") { model.downloadModels() }
                            .buttonStyle(RedTextButtonStyle())
                            .disabled(model.isBusy)
                    }
                    Button("Choose Folder…") { model.chooseModelsFolder() }
                        .disabled(model.isBusy)
                }
                .controlSize(.small)
            }
            .frame(height: 46)
        }
    }

    private var actionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusView
            HStack(spacing: 12) {
                if model.isBusy {
                    Button(role: .cancel) { model.cancel() } label: {
                        Text("Cancel").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else {
                    Button { model.startUpscale() } label: {
                        Label("Upscale ×\(model.scale.rawValue)", systemImage: "wand.and.stars")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(violet)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canUpscale || !model.engineReady)
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.phase {
        case .idle:
            if model.videoInfo == nil {
                hint("Choose a video to begin")
            } else if !model.engineReady {
                hint("The engine is missing from this app. Rebuild it with the build scripts.")
            } else if model.modelsFolder == nil {
                hint("Choose a folder for the model files.")
            } else {
                hint(model.missingModels.isEmpty ? "Ready." : "The model files will be downloaded first.")
            }
        case .downloading(let name, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading \(name)…").font(.callout)
                ProgressView(value: fraction).tint(accent)
            }
        case .working(let text, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    HStack {
                        Text(text).font(.callout).lineLimit(1)
                        Spacer()
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.callout.monospacedDigit().weight(.semibold))
                    }
                    ProgressView(value: fraction).tint(accent)
                } else {
                    progressRow(text)
                }
                if let start = model.upscaleStartedAt {
                    // Redrawn every second.
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("Elapsed \(Self.clock(context.date.timeIntervalSince(start)))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        case .notice(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .finished(let url, let took):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Upscaling finished: \(url.lastPathComponent)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Took \(Self.clock(took))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        case .cancelled:
            hint(model.missingModels.isEmpty
                 ? "Cancelled."
                 : "Cancelled. Partial downloads are kept and will resume next time.")
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Something went wrong", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Helpers

    private var modelStatus: String {
        guard model.modelsFolder != nil else {
            return "Choose a folder. Missing model files download there."
        }
        if model.missingModels.isEmpty {
            return "All model files for ×2 and ×4 are present."
        }
        let size = model.missingModels.reduce(0) { $0 + $1.approxSizeGB }
        return String(format: "%d file(s) to download, about %.1f GB.", model.missingModels.count, size)
    }

    /// "1920×1080 · 29.97 fps · 1:05 · /path/to/folder"
    private func videoDetails(_ url: URL) -> String {
        guard let info = model.videoInfo else { return url.deletingLastPathComponent().path }
        let size = info.displaySize
        let fps = info.fps.rounded() == info.fps ? String(Int(info.fps)) : String(format: "%.2f", info.fps)
        let total = Int(info.duration.rounded())
        let length = total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
        return "\(Int(size.width))×\(Int(size.height)) · \(fps) fps · \(length) · \(url.deletingLastPathComponent().path)"
    }

    /// 0:42, 12:05, 1:02:09
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.6))
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in model.setVideo(url) }
        }
        return true
    }
}

/// Removes the resize handle from the hosting window, so it keeps the size its content needs.
private struct FixedWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.styleMask.remove(.resizable)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.styleMask.remove(.resizable)
        }
    }
}

/// Looks like a standard small bordered button, but keeps its label red.
private struct RedTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(isEnabled ? Color.red : Color.red.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
    }
}

/// A rounded panel used for each section.
private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.5))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
}
