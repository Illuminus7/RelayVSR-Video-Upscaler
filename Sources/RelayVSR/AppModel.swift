import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case notice(String)
        case cancelled
        case downloading(String, Double)
        case working(String, Double?)
        /// The saved file, and how long the upscaling took.
        case finished(URL, TimeInterval)
        case failed(String)
    }

    @Published private(set) var videoURL: URL?
    @Published private(set) var videoInfo: VideoInfo?
    /// Every launch starts at ×2; the choice is not remembered.
    @Published var scale: Scale = .x2
    @Published private(set) var modelsFolder: URL?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var missingModels: [ModelFile] = []
    /// When the running upscale started (after any model downloads), for the elapsed time.
    @Published private(set) var upscaleStartedAt: Date?
    let engineReady = EngineLocation.bundled.isReady

    private let defaults = UserDefaults.standard
    private let engine = ComfyEngine(location: .bundled)
    private var jobTask: Task<Void, Never>?
    /// The running job. Progress from any other (finished) job is ignored, so a late update
    /// can never overwrite the final state.
    private var jobID: UUID?
    private var videoCheck: UUID?
    private var idleStopTask: Task<Void, Never>?

    /// The engine stays loaded this long after a job, so the next job starts quickly.
    private static let engineIdleSeconds: UInt64 = 300

    private enum Keys {
        static let modelsFolder = "modelsFolder"
        /// Hidden setting for testing: fixed frames per part instead of the memory-based size.
        static let chunkFrames = "chunkFrames"
    }

    init() {
        modelsFolder = defaults.string(forKey: Keys.modelsFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }

        // Clear what an earlier run may have left after a crash or a quit mid-job:
        // engine processes first, then the work files they were using.
        ComfyEngine.killOrphans(location: .bundled)
        AppPaths.cleanWorkFolders()
        if let folder = modelsFolder {
            for file in allModelFiles { ModelDownloader.removeLeftoverJoin(of: file, in: folder) }
        }
        refreshMissingModels()

        // Runs synchronously on the main thread before the app exits, so the engine is
        // stopped (and not left running) when the app quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown() }
        }
    }

    // MARK: - Derived state

    var isBusy: Bool {
        switch phase {
        case .downloading, .working: return true
        default: return false
        }
    }

    var canUpscale: Bool { videoInfo != nil && modelsFolder != nil && engineReady && !isBusy }

    /// Every model file, for both ×2 and ×4. They are downloaded together.
    private var allModelFiles: [ModelFile] {
        Scale.allCases.flatMap { $0.requiredFiles }
    }

    // MARK: - Selection

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            setVideo(url)
        }
    }

    /// Accepts the file only if macOS can read it as a video.
    func setVideo(_ url: URL) {
        guard !isBusy else { return }
        let check = UUID()
        videoCheck = check
        Task {
            do {
                let info = try await VideoInfo.load(url)
                guard videoCheck == check else { return }
                videoURL = url
                videoInfo = info
                phase = .idle
            } catch {
                guard videoCheck == check else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where the RelayVSR models are stored"
        panel.message = "Pick a ComfyUI models folder (the one holding diffusion_models and vae), or an empty folder for the downloads."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        let (folder, note) = normalizedModelsFolder(picked)
        modelsFolder = folder
        defaults.set(folder.path, forKey: Keys.modelsFolder)
        refreshMissingModels()
        phase = note.map { .notice($0) } ?? .idle
    }

    /// ComfyUI needs the files in `diffusion_models/` and `vae/` under the chosen folder.
    /// Common mistakes are corrected here, so they don't trigger a 10 GB download.
    private func normalizedModelsFolder(_ url: URL) -> (URL, String?) {
        let fm = FileManager.default
        func hasLayout(_ folder: URL) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent("diffusion_models").path)
                || fm.fileExists(atPath: folder.appendingPathComponent("vae").path)
        }
        let name = url.lastPathComponent
        if name == "diffusion_models" || name == "vae" {
            let parent = url.deletingLastPathComponent()
            return (parent, "Using “\(parent.lastPathComponent)”, the folder that holds \(name).")
        }
        let nested = url.appendingPathComponent("models", isDirectory: true)
        if !hasLayout(url) && hasLayout(nested) {
            return (nested, "Using the models folder inside “\(name)”.")
        }
        if allModelFiles.contains(where: { fm.fileExists(atPath: url.appendingPathComponent($0.name).path) }) {
            return (url, "Model files sit directly in this folder. They must be in its diffusion_models and vae subfolders; move them there to avoid downloading them again.")
        }
        return (url, nil)
    }

    func refreshMissingModels() {
        guard let folder = modelsFolder else {
            missingModels = allModelFiles
            return
        }
        missingModels = allModelFiles.filter { !$0.isPresent(in: folder) }
    }

    // MARK: - Actions

    func downloadModels() {
        guard !isBusy, let folder = modelsFolder else { return }
        let id = beginJob()
        jobTask = Task { [self] in
            do {
                try await ensureModels(in: folder, job: id)
                endJob(id, .idle)
            } catch is CancellationError {
                endJob(id, .cancelled)
            } catch {
                endJob(id, .failed(error.localizedDescription))
            }
        }
    }

    func startUpscale() {
        guard canUpscale, let video = videoURL, let info = videoInfo, let folder = modelsFolder else { return }
        let chosenScale = scale
        let override = defaults.integer(forKey: Keys.chunkFrames)
        let id = beginJob()

        jobTask = Task { [self] in
            do {
                try await ensureModels(in: folder, job: id)
                let started = Date()
                upscaleStartedAt = started
                let output = try await Upscaler.run(input: video, info: info, scale: chosenScale,
                                                    modelsFolder: folder, engine: engine,
                                                    chunkFramesOverride: override > 0 ? override : nil) { [weak self] text, fraction in
                    Task { @MainActor in self?.update(id, .working(text, fraction)) }
                }
                endJob(id, .finished(output, Date().timeIntervalSince(started)))
            } catch is CancellationError {
                endJob(id, .cancelled)
            } catch {
                endJob(id, .failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        jobTask?.cancel()
    }

    /// Cancels a running job and stops the engine when the app quits.
    func shutDown() {
        jobTask?.cancel()
        idleStopTask?.cancel()
        engine.stop()
    }

    // MARK: - Jobs

    private func beginJob() -> UUID {
        idleStopTask?.cancel()
        let id = UUID()
        jobID = id
        return id
    }

    private func update(_ id: UUID, _ newPhase: Phase) {
        guard jobID == id else { return }
        phase = newPhase
    }

    private func endJob(_ id: UUID, _ finalPhase: Phase) {
        guard jobID == id else { return }
        jobID = nil
        upscaleStartedAt = nil
        phase = finalPhase
        refreshMissingModels()
        scheduleIdleStop()
    }

    /// Stops the engine after a few idle minutes, to give its memory back.
    private func scheduleIdleStop() {
        idleStopTask?.cancel()
        guard engine.isRunning else { return }
        let engine = self.engine
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.engineIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled, self?.jobID == nil else { return }
            await Task.detached { engine.stop() }.value
        }
    }

    private func ensureModels(in folder: URL, job id: UUID) async throws {
        for file in allModelFiles where !file.isPresent(in: folder) {
            let name = file.name
            update(id, .downloading(name, 0))
            try await ModelDownloader.download(file, into: folder) { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .progress(let fraction):
                        self?.update(id, .downloading(name, fraction))
                    case .joining:
                        self?.update(id, .working("Joining and checking \(name)…", nil))
                    }
                }
            }
        }
    }
}
