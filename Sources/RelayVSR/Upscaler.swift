import Foundation

/// The engine ran out of memory on a part. The part is retried smaller.
struct EngineOutOfMemory: Error {}

/// Runs one upscale job end to end and returns the finished file's URL.
///
/// The video is upscaled in parts that fit in memory (see `PartSizing`). Each part is a
/// separate ComfyUI run that writes a short video; if one runs out of memory it is retried at
/// half the size. The parts are then joined, with the original audio, into
/// "<name> upscaled.<ext>" next to the original.
enum Upscaler {
    static func run(input: URL,
                    info: VideoInfo,
                    scale: Scale,
                    modelsFolder: URL,
                    engine: ComfyEngine,
                    chunkFramesOverride: Int? = nil,
                    report: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        let fm = FileManager.default
        var partFrames = try chunkFramesOverride ?? PartSizing.initialFrames(for: info, scale: scale)
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let ext = input.pathExtension.lowercased()

        // The engine reads only from its input folder. A hard link avoids copying gigabytes;
        // a copy is the fallback when the video is on another volume. Removed when the job ends,
        // and at the next launch if the app quits before that.
        try fm.createDirectory(at: AppPaths.input, withIntermediateDirectories: true)
        let inputName = "relayvsr-\(token).\(ext.isEmpty ? "mp4" : ext)"
        let linkedInput = AppPaths.input.appendingPathComponent(inputName)
        do {
            try fm.linkItem(at: input, to: linkedInput)
        } catch {
            report("Preparing the video…", nil)
            try fm.copyItem(at: input, to: linkedInput)
        }
        defer { try? fm.removeItem(at: linkedInput) }

        var parts: [URL] = []
        defer { for part in parts { try? fm.removeItem(at: part) } }

        let jobStart = Date()
        report("Starting engine…", 0)
        try await engine.start(modelsFolder: modelsFolder)
        let clientID = UUID().uuidString

        let total = info.frameCount
        var cursor = 0              // first frame of the next part
        // Overall progress: frames finished plus the running part's share. The last 2% is the join.
        func overall(_ partFraction: Double, size: Int) -> Double {
            min(0.98, (Double(cursor) + Double(size) * partFraction) / Double(total) * 0.98)
        }
        while cursor < total {
            try Task.checkCancellation()

            // The frame count is an estimate, so a remainder under 5 frames joins this part;
            // the last part always runs to the end of the video.
            let size = min(partFrames, total - cursor)
            let isLast = total - (cursor + size) < 5
            let partFrameCount = isLast ? total - cursor : size
            let start = PartSizing.time(ofFrame: cursor, fps: info.fps)
            let duration = isLast ? 0 : PartSizing.time(ofFrame: cursor + size, fps: info.fps) - start
            let prefix = "relayvsr-\(token)-\(String(format: "%06d", cursor))"
            let graph = RelayVSRWorkflow.graph(inputFileName: inputName, scale: scale,
                                               start: start, duration: duration, outputPrefix: prefix)
            report(progressText(scale: scale, fraction: overall(0, size: partFrameCount), since: jobStart),
                   overall(0, size: partFrameCount))
            do {
                // The engine may have been stopped by an out-of-memory crash on the previous try.
                try await engine.start(modelsFolder: modelsFolder)
                let client = ComfyClient(baseURL: engine.baseURL)
                let monitor = ProgressMonitor(baseURL: engine.baseURL, clientID: clientID)
                defer { monitor.close() }
                let promptID = try await client.queue(graph, clientID: clientID)
                do {
                    parts.append(try await waitForOutput(client: client, engine: engine, promptID: promptID, prefix: prefix) {
                        // The decoder reports once per frame; it is nearly all of a part's time.
                        let decoded = monitor.fraction(promptID: promptID, node: "104") ?? 0
                        let fraction = overall(decoded * 0.95, size: partFrameCount)
                        report(progressText(scale: scale, fraction: fraction, since: jobStart), fraction)
                    })
                } catch is CancellationError {
                    await client.interrupt()
                    throw CancellationError()
                }
            } catch is EngineOutOfMemory {
                guard size > 1 else { throw PartSizing.tooLarge(info: info, scale: scale) }
                partFrames = max(1, size / 2)
                report("Not enough memory for \(size) frames at once; retrying with \(partFrames)…",
                       overall(0, size: partFrameCount))
                continue
            }
            cursor += partFrameCount
        }

        report(parts.count > 1 ? "Joining \(parts.count) parts…" : "Saving…", 0.98)
        let folder = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let destination = uniqueDestination(in: folder, baseName: "\(base) upscaled", ext: "mp4")
        do {
            try await VideoAssembler.assemble(parts: parts, source: input, info: info, scale: scale, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        report("Done", 1)
        return destination
    }

    /// "Upscaling ×2 — about 12 min left". The estimate appears only after 25% is done, when
    /// the model loading at the start no longer skews it.
    private static func progressText(scale: Scale, fraction: Double, since start: Date) -> String {
        let text = "Upscaling ×\(scale.rawValue)"
        let elapsed = Date().timeIntervalSince(start)
        guard fraction >= 0.25 else { return text + "…" }
        return text + " — " + formatRemaining(elapsed * (1 - fraction) / fraction)
    }

    private static func formatRemaining(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "about a minute left" }
        if minutes < 90 { return "about \(minutes) min left" }
        return String(format: "about %.1f h left", seconds / 3600)
    }

    /// Polls the history until the prompt finishes, then returns the saved part's path.
    private static func waitForOutput(client: ComfyClient, engine: ComfyEngine,
                                      promptID: String, prefix: String,
                                      tick: () -> Void) async throws -> URL {
        while true {
            try Task.checkCancellation()
            tick()
            // An engine that died mid-part was almost always killed for using too much memory.
            guard engine.isRunning else { throw EngineOutOfMemory() }
            let entry: [String: Any]?
            do {
                entry = try await client.history(for: promptID)
            } catch {
                if !engine.isRunning { throw EngineOutOfMemory() }
                throw error
            }
            if let entry, let status = entry["status"] as? [String: Any] {
                if (status["status_str"] as? String) == "error" {
                    let detail = describeError(entry)
                    if detail.localizedCaseInsensitiveContains("out of memory") { throw EngineOutOfMemory() }
                    throw AppError("The upscale failed inside ComfyUI. \(detail)")
                }
                if (status["completed"] as? Bool) == true {
                    return try locateOutput(in: entry, prefix: prefix)
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func locateOutput(in entry: [String: Any], prefix: String) throws -> URL {
        let outputs = entry["outputs"] as? [String: Any] ?? [:]
        for (_, nodeOutput) in outputs {
            guard let fields = nodeOutput as? [String: Any] else { continue }
            for (_, value) in fields {
                guard let items = value as? [[String: Any]] else { continue }
                for item in items {
                    // LoadVideo also echoes its input; only "output" items count.
                    guard (item["type"] as? String) == "output",
                          let filename = item["filename"] as? String, filename.hasPrefix(prefix) else { continue }
                    let subfolder = item["subfolder"] as? String ?? ""
                    var url = AppPaths.output
                    if !subfolder.isEmpty {
                        url = url.appendingPathComponent(subfolder, isDirectory: true)
                    }
                    url = url.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                }
            }
        }
        throw AppError("ComfyUI finished, but the upscaled video was not found in the output folder.")
    }

    private static func describeError(_ entry: [String: Any]) -> String {
        let status = entry["status"] as? [String: Any] ?? [:]
        let messages = status["messages"] as? [[Any]] ?? []
        for message in messages {
            if message.count > 1, let payload = message[1] as? [String: Any],
               let text = payload["exception_message"] as? String {
                let node = (payload["node_type"] as? String).map { "(\($0)) " } ?? ""
                return node + text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    /// "<base>.<ext>" if free, otherwise "<base> 2.<ext>", "<base> 3.<ext>", and so on.
    private static func uniqueDestination(in folder: URL, baseName: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
