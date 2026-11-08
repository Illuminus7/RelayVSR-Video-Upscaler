import Foundation

/// A user-facing error. Messages are shown in the UI and never written to disk.
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Where the app keeps its own working files, under ~/Library/Application Support/RelayVSR.
/// Files here exist only while a job runs. No log files are created.
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RelayVSR", isDirectory: true)
    }()

    static let input = root.appendingPathComponent("input", isDirectory: true)
    static let output = root.appendingPathComponent("output", isDirectory: true)
    static let temp = root.appendingPathComponent("temp", isDirectory: true)
    static let user = root.appendingPathComponent("user", isDirectory: true)
    static let extraModelPaths = root.appendingPathComponent("extra_model_paths.yaml")

    /// Empties the input, output and temp folders. Run at launch, before the engine starts,
    /// to remove whatever an interrupted job (a crash or a quit mid-job) left behind.
    static func cleanWorkFolders() {
        let fm = FileManager.default
        for folder in [input, output, temp] {
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                try? fm.removeItem(at: entry)
            }
        }
    }
}

/// The ComfyUI engine that ships inside the app bundle:
///   Resources/Engine/python      standalone Python 3.13 with PyTorch and ComfyUI's requirements
///   Resources/Engine/ComfyUI     ComfyUI, with custom_nodes/ComfyUI-AppleSilicon-int8-Fast
struct EngineLocation {
    let comfyDir: URL
    let python: URL

    static var bundled: EngineLocation {
        let engine = Bundle.main.resourceURL!.appendingPathComponent("Engine", isDirectory: true)
        return EngineLocation(comfyDir: engine.appendingPathComponent("ComfyUI", isDirectory: true),
                              python: engine.appendingPathComponent("python/bin/python3"))
    }

    var isReady: Bool {
        FileManager.default.fileExists(atPath: comfyDir.appendingPathComponent("main.py").path)
            && FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: comfyDir.appendingPathComponent("custom_nodes/ComfyUI-AppleSilicon-int8-Fast").path)
    }
}
