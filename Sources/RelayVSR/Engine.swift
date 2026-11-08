import Darwin
import Foundation

/// Runs the bundled ComfyUI headless on localhost.
///
/// - It listens on a free port picked at start, so it never collides with another program.
/// - Its output is kept only as a short tail in memory, to explain failures. Nothing is logged.
/// - It stays running between jobs (the app stops it after a few idle minutes), and restarts
///   when the models folder changes.
final class ComfyEngine: @unchecked Sendable {
    private let location: EngineLocation
    private let lock = NSLock()
    private var process: Process?
    private var outputPipe: Pipe?
    private var port = 0
    private var modelsFolder: URL?
    private let tail = OutputTail()

    init(location: EngineLocation) {
        self.location = location
    }

    var baseURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// The engine's last output lines, for error messages.
    var recentOutput: String { tail.lastLines(12) }

    /// An error describing why the engine is no longer running.
    func stoppedError(_ context: String) -> AppError {
        let detail = recentOutput
        return AppError(detail.isEmpty ? context : "\(context)\n\(detail)")
    }

    func start(modelsFolder folder: URL) async throws {
        let (running, sameFolder) = lock.withLock {
            (process?.isRunning == true, modelsFolder?.standardizedFileURL == folder.standardizedFileURL)
        }
        if running && sameFolder { return }
        if running { stop() }   // the models folder changed; it is read only at start

        guard location.isReady else {
            throw AppError("The bundled engine is missing from this app. Rebuild the app with scripts/build_app.sh.")
        }
        try prepareFolders()
        try writeExtraModelPaths(folder)
        let freePort = try Self.freeLocalPort()

        let p = Process()
        p.executableURL = location.python
        p.currentDirectoryURL = location.comfyDir
        p.arguments = [
            "main.py",
            "--listen", "127.0.0.1",
            "--port", String(freePort),
            "--disable-auto-launch",
            "--input-directory", AppPaths.input.path,
            "--output-directory", AppPaths.output.path,
            "--temp-directory", AppPaths.temp.path,
            "--user-directory", AppPaths.user.path,
            "--extra-model-paths-config", AppPaths.extraModelPaths.path,
        ]
        // Keep the bundle free of __pycache__ and ignore the user's own Python packages.
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        p.environment = environment
        p.standardInput = FileHandle.nullDevice

        tail.reset()
        let pipe = Pipe()
        let tail = self.tail
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(data)
            }
        }
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()

        lock.withLock {
            process = p
            outputPipe = pipe
            port = freePort
            modelsFolder = folder
        }

        let client = ComfyClient(baseURL: baseURL)
        do {
            for _ in 0..<300 {
                try Task.checkCancellation()
                if !p.isRunning {
                    throw stoppedError("The engine stopped while starting.")
                }
                if await client.isAlive() { return }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            throw stoppedError("The engine did not start within five minutes.")
        } catch {
            stop()
            throw error
        }
    }

    /// Stops the engine and waits for it to exit. If it has not exited after a few seconds, it is killed.
    func stop() {
        lock.lock()
        let p = process
        let pipe = outputPipe
        process = nil
        outputPipe = nil
        modelsFolder = nil
        lock.unlock()
        defer { pipe?.fileHandleForReading.readabilityHandler = nil }
        guard let p, p.isRunning else { return }

        p.terminate()
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
    }

    /// Kills engine processes left over from an earlier run that did not shut down (a crash or
    /// a force quit). Only processes running this app's bundled Python are matched, and the app
    /// allows one copy of itself, so none of them belongs to a running job.
    static func killOrphans(location: EngineLocation) {
        let target = location.python.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 && pid != getpid() {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if path == target {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: Helpers

    /// Asks the system for a free TCP port on localhost.
    private static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError("Could not open a local port for the engine.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw AppError("Could not open a local port for the engine.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func prepareFolders() throws {
        let fm = FileManager.default
        for folder in [AppPaths.input, AppPaths.output, AppPaths.temp, AppPaths.user] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Points ComfyUI at the models folder the user chose, without copying anything.
    private func writeExtraModelPaths(_ modelsFolder: URL) throws {
        let escaped = modelsFolder.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let yaml = """
        relayvsr:
            base_path: "\(escaped)"
            diffusion_models: diffusion_models
            vae: vae

        """
        try yaml.write(to: AppPaths.extraModelPaths, atomically: true, encoding: .utf8)
    }
}

/// Keeps the last few kilobytes of the engine's output, in memory only.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 16_000

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit {
            data = data.suffix(limit)
        }
    }

    func reset() {
        lock.lock()
        data = Data()
        lock.unlock()
    }

    func lastLines(_ count: Int) -> String {
        lock.lock()
        let text = String(decoding: data, as: UTF8.self)
        lock.unlock()
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(count).joined(separator: "\n")
    }
}

/// Listens to ComfyUI's websocket for the progress bars nodes report while they run
/// (the RelayVSR decoder reports one step per decoded frame). Keeps only the latest value.
final class ProgressMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [String: (value: Double, max: Double)] = [:]   // keyed by "promptID/node"
    private let task: URLSessionWebSocketTask
    private var listener: Task<Void, Never>?

    init(baseURL: URL, clientID: String) {
        var components = URLComponents(url: baseURL.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        task = URLSession.shared.webSocketTask(with: components.url!)
        task.resume()
        listener = Task { [weak self] in await self?.listen() }
    }

    /// Fraction (0…1) of the given node's progress bar in the given prompt, if it has reported.
    func fraction(promptID: String, node: String) -> Double? {
        lock.withLock {
            guard let entry = latest["\(promptID)/\(node)"], entry.max > 0 else { return nil }
            return min(1, entry.value / entry.max)
        }
    }

    func close() {
        listener?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func listen() async {
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { return }
            guard case .string(let text) = message,
                  let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  json["type"] as? String == "progress",
                  let data = json["data"] as? [String: Any],
                  let prompt = data["prompt_id"] as? String,
                  let node = data["node"] as? String,
                  let value = (data["value"] as? NSNumber)?.doubleValue,
                  let max = (data["max"] as? NSNumber)?.doubleValue else { continue }
            lock.withLock { latest["\(prompt)/\(node)"] = (value, max) }
        }
    }
}

/// Minimal client for ComfyUI's HTTP API.
struct ComfyClient {
    let baseURL: URL

    func isAlive() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("system_stats"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Queues a graph and returns the prompt id.
    func queue(_ graph: [String: Any], clientID: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("prompt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": graph, "client_id": clientID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let promptID = json["prompt_id"] as? String else {
            let body = String(decoding: data, as: UTF8.self)
            throw AppError("ComfyUI rejected the workflow. \(body.prefix(600))")
        }
        return promptID
    }

    /// Returns the history entry for a prompt, or nil while it is still queued or running.
    func history(for promptID: String) async throws -> [String: Any]? {
        let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("history/\(promptID)"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?[promptID] as? [String: Any]
    }

    func interrupt() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("interrupt"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }
}
