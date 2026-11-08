import CryptoKit
import Foundation

/// What a download reports while it runs.
enum DownloadEvent: Sendable {
    case progress(Double)
    case joining
}

/// Downloads one model file as four parts at the same time, then joins the parts.
///
/// - Parts are written to `<name>.<hash>.part1` … `.part4` next to the final file. The hash
///   prefix ties the parts to one version of the file, so parts from an older upload are
///   never mixed with a newer one.
/// - Cancelling keeps the parts. The next download resumes each part where it stopped.
/// - When every part is complete they are copied in order into `<name>.joining` while the
///   SHA-256 is computed. If the hash matches, the result becomes `<name>` and the parts are
///   removed. Joining needs room for a second copy of the file until then.
enum ModelDownloader {
    static let partCount = 4

    static func download(_ file: ModelFile,
                         into folder: URL,
                         events: @escaping @Sendable (DownloadEvent) -> Void) async throws {
        let fm = FileManager.default
        let finalURL = file.localURL(in: folder)
        if file.isPresent(in: folder) { return }
        let directory = finalURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let info = try await ProbeRequest.run(url: file.remoteURL)
        try Task.checkCancellation()
        let linked = await LinkedMetadata.fetch(url: file.remoteURL)
        // The hash Hugging Face reports now, or the one this app shipped with for the same size.
        let expectedSHA = linked?.sha256 ?? (info.total == file.knownSize ? file.knownSHA256 : nil)

        let tag = expectedSHA.map { "." + $0.prefix(12) } ?? ""
        let partURLs = (1...partCount).map { directory.appendingPathComponent("\(file.name)\(tag).part\($0)") }
        removeStaleParts(of: file.name, in: directory, keeping: Set(partURLs.map(\.lastPathComponent)))
        try checkFreeSpace(in: directory, total: info.total, partURLs: partURLs)

        let transfer = ParallelTransfer(remote: file.remoteURL,
                                        partURLs: partURLs,
                                        total: info.total,
                                        ranges: info.ranges,
                                        progress: { events(.progress($0)) })

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                transfer.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            transfer.cancel()
        }

        // Every part is complete. Joining is local and short, so it is not interrupted.
        events(.joining)
        try ModelJoiner.join(partURLs: transfer.partURLs, into: finalURL,
                             expectedSize: info.total, expectedSHA256: expectedSHA)
    }

    /// Removes the `.joining` file a failed join may have left behind.
    static func removeLeftoverJoin(of file: ModelFile, in folder: URL) {
        try? FileManager.default.removeItem(at: file.localURL(in: folder).appendingPathExtension("joining"))
    }

    /// Deletes parts of this file that belong to another version (another hash tag).
    private static func removeStaleParts(of name: String, in directory: URL, keeping current: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for entry in entries where entry.hasPrefix(name + ".") && entry.contains(".part") && !current.contains(entry) {
            try? fm.removeItem(at: directory.appendingPathComponent(entry))
        }
    }

    /// The rest of the download plus a full second copy for the join must fit on the disk.
    private static func checkFreeSpace(in directory: URL, total: Int64, partURLs: [URL]) throws {
        let fm = FileManager.default
        let existing = partURLs.reduce(Int64(0)) { sum, url in
            sum + ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0)
        }
        let needed = (total - existing) + total + 200_000_000
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values?.volumeAvailableCapacityForImportantUsage, available < needed {
            throw AppError(String(format: "Not enough free space in the models folder: %.1f GB needed, %.1f GB free.",
                                  Double(needed) / 1e9, Double(available) / 1e9))
        }
    }
}

/// Hugging Face reports a file's size and SHA-256 on the redirect it answers with.
/// The redirect is not followed, so this reads headers only.
private enum LinkedMetadata {
    static func fetch(url: URL) async -> (size: Int64?, sha256: String)? {
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: ModelSession.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              let etag = http.value(forHTTPHeaderField: "X-Linked-ETag") else { return nil }
        let sha = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\" W/")).lowercased()
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        return (Int64(http.value(forHTTPHeaderField: "X-Linked-Size") ?? ""), sha)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

// MARK: - Probe

/// Reads the file size and whether the server accepts byte ranges, from a one-byte request.
/// The body is cancelled as soon as the headers arrive, so no file data is read here.
private enum ProbeRequest {
    static func run(url: URL) async throws -> (total: Int64, ranges: Bool) {
        let delegate = ProbeDelegate()
        let session = URLSession(configuration: ModelSession.configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let http: HTTPURLResponse = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.dataTask(with: request).resume()
        }

        switch http.statusCode {
        case 206:
            guard let total = ContentRange.total(from: http.value(forHTTPHeaderField: "Content-Range")) else {
                throw AppError("The server did not report the size of the model file.")
            }
            return (total, true)
        case 200..<300:
            guard let length = Int64(http.value(forHTTPHeaderField: "Content-Length") ?? ""), length > 0 else {
                throw AppError("The server did not report the size of the model file.")
            }
            return (length, false)
        default:
            throw AppError("The model download failed (HTTP \(http.statusCode)).")
        }
    }
}

private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var answered = false

    private func answer(_ result: Result<HTTPURLResponse, Error>) {
        guard !answered, let continuation else { return }
        answered = true
        self.continuation = nil
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        if let http = response as? HTTPURLResponse {
            answer(.success(http))
        } else {
            answer(.failure(AppError("The server sent an unexpected response.")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            answer(.failure(error))
        }
    }
}

// MARK: - Parallel transfer

/// Runs one data task per part on a serial queue. All state is touched only on that queue.
private final class ParallelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Part {
        let start: Int64
        let end: Int64
        let url: URL
        var received: Int64 = 0
        var attempts = 0
        var handle: FileHandle?

        var length: Int64 { end - start + 1 }
        var isComplete: Bool { received >= length }
    }

    private static let maxAttempts = 6

    let remote: URL
    let partURLs: [URL]
    private let total: Int64
    private let ranges: Bool
    private let progress: @Sendable (Double) -> Void

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var session: URLSession?
    private var parts: [Part] = []
    private var taskToPart: [Int: Int] = [:]
    private var completion: ((Result<Void, Error>) -> Void)?
    private var cancelled = false
    private var lastReport = Date.distantPast

    init(remote: URL, partURLs: [URL], total: Int64, ranges: Bool, progress: @escaping @Sendable (Double) -> Void) {
        let count = ranges ? partURLs.count : 1
        self.remote = remote
        self.partURLs = Array(partURLs.prefix(count))
        self.total = total
        self.ranges = ranges
        self.progress = progress
        super.init()

        // Split the file into equal byte ranges, one per part. Without range support the
        // whole file is one part, which cannot resume.
        let size = total / Int64(count)
        for index in 0..<count {
            let start = Int64(index) * size
            let end = index == count - 1 ? total - 1 : start + size - 1
            parts.append(Part(start: start, end: end, url: partURLs[index]))
        }
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.addOperation { [self] in
            self.completion = completion
            if self.cancelled {
                self.finish(.failure(CancellationError()))
                return
            }
            do {
                try self.openParts()
            } catch {
                self.finish(.failure(error))
                return
            }
            let config = ModelSession.configuration()
            config.httpMaximumConnectionsPerHost = max(4, self.parts.count)
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: self.queue)

            if self.parts.allSatisfy({ $0.isComplete }) {
                self.finish(.success(()))
                return
            }
            for index in self.parts.indices where !self.parts[index].isComplete {
                self.launch(index)
            }
        }
    }

    func cancel() {
        queue.addOperation { [self] in
            guard !self.cancelled else { return }
            self.cancelled = true
            self.finish(.failure(CancellationError()))
        }
    }

    // MARK: Part files (queue only)

    /// Opens or creates each part file and works out how much of it is already there.
    private func openParts() throws {
        let fm = FileManager.default
        for index in parts.indices {
            let part = parts[index]
            if !fm.fileExists(atPath: part.url.path) {
                guard fm.createFile(atPath: part.url.path, contents: nil) else {
                    throw AppError("Could not create \(part.url.lastPathComponent).")
                }
            }
            let handle = try FileHandle(forUpdating: part.url)
            var received = Int64(try handle.seekToEnd())
            if received > part.length || !ranges {
                // Too much data, or no range support: start this part again.
                try handle.truncate(atOffset: 0)
                received = 0
            }
            parts[index].received = received
            parts[index].handle = handle
        }
    }

    private func launch(_ index: Int) {
        guard let session else { return }
        var request = URLRequest(url: remote, timeoutInterval: 60)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if ranges {
            let from = parts[index].start + parts[index].received
            request.setValue("bytes=\(from)-\(parts[index].end)", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        taskToPart[task.taskIdentifier] = index
        task.resume()
    }

    private func reportProgress(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = now
        let done = parts.reduce(Int64(0)) { $0 + $1.received }
        progress(min(1, Double(done) / Double(total)))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let completion else { return }
        self.completion = nil
        session?.invalidateAndCancel()
        session = nil
        taskToPart.removeAll()
        for index in parts.indices {
            try? parts[index].handle?.close()
            parts[index].handle = nil
        }
        if case .success = result {
            reportProgress(force: true)
        }
        completion(result)
    }

    private func fail(_ error: Error) {
        finish(.failure(error))
    }

    // MARK: URLSessionDataDelegate (queue)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let index = taskToPart[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let expected = ranges ? 206 : 200
        guard http.statusCode == expected else {
            completionHandler(.cancel)
            fail(AppError("The model download failed (HTTP \(http.statusCode))."))
            return
        }
        if ranges {
            let from = parts[index].start + parts[index].received
            guard ContentRange.start(from: http.value(forHTTPHeaderField: "Content-Range")) == from else {
                completionHandler(.cancel)
                fail(AppError("The server returned an unexpected byte range."))
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let index = taskToPart[dataTask.taskIdentifier] else { return }
        let remaining = parts[index].length - parts[index].received
        let count = Int(min(Int64(data.count), remaining))
        guard count > 0, let handle = parts[index].handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data.prefix(count))
        } catch {
            fail(error)
            return
        }
        parts[index].received += Int64(count)
        parts[index].attempts = 0
        reportProgress()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = taskToPart.removeValue(forKey: task.taskIdentifier) else { return }
        guard !cancelled, completion != nil else { return }

        if parts[index].isComplete {
            if parts.allSatisfy({ $0.isComplete }) {
                finish(.success(()))
            }
            return
        }

        // The connection ended early. Resume this part from where it stopped.
        parts[index].attempts += 1
        if parts[index].attempts > Self.maxAttempts {
            fail(AppError("A download part failed: \(error?.localizedDescription ?? "the connection ended early")"))
            return
        }
        if !ranges {
            // Without range support a part cannot resume, so it starts again from the beginning.
            parts[index].received = 0
            try? parts[index].handle?.truncate(atOffset: 0)
        }
        let delay = min(0.5 * pow(2.0, Double(parts[index].attempts - 1)), 8)
        queue.addOperation(afterDelay: delay) { [weak self] in
            guard let self, !self.cancelled, self.completion != nil else { return }
            self.launch(index)
        }
    }
}

private extension OperationQueue {
    /// Adds an operation to run on this queue after a delay.
    func addOperation(afterDelay delay: TimeInterval, _ block: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            self.addOperation(block)
        }
    }
}

// MARK: - Joining

enum ModelJoiner {
    private static let chunkSize = 8 << 20

    /// Copies the parts, in order, into `finalURL` while hashing them, then removes the parts.
    /// On any failure the half-written `.joining` file is removed; the parts are kept unless
    /// the hash proves them wrong.
    static func join(partURLs: [URL], into finalURL: URL, expectedSize: Int64, expectedSHA256: String?) throws {
        let fm = FileManager.default
        let joining = finalURL.appendingPathExtension("joining")
        try? fm.removeItem(at: joining)
        guard fm.createFile(atPath: joining.path, contents: nil) else {
            throw AppError("Could not create \(joining.lastPathComponent).")
        }

        var hasher = SHA256()
        do {
            let output = try FileHandle(forWritingTo: joining)
            defer { try? output.close() }
            for part in partURLs {
                let input = try FileHandle(forReadingFrom: part)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                    hasher.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
        } catch {
            try? fm.removeItem(at: joining)
            throw AppError("Could not join the downloaded parts: \(error.localizedDescription)")
        }

        let joinedSize = (try? fm.attributesOfItem(atPath: joining.path)[.size] as? Int64) ?? -1
        guard joinedSize == expectedSize else {
            try? fm.removeItem(at: joining)
            throw AppError("The joined model file has the wrong size. The parts are kept, so the download can be retried.")
        }

        if let expectedSHA256 {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedSHA256 else {
                // The parts themselves are bad, so resuming from them would fail again.
                try? fm.removeItem(at: joining)
                for part in partURLs { try? fm.removeItem(at: part) }
                throw AppError("\(finalURL.lastPathComponent) failed its checksum and was deleted. Download it again.")
            }
        }

        try? fm.removeItem(at: finalURL)
        try fm.moveItem(at: joining, to: finalURL)
        for part in partURLs {
            try? fm.removeItem(at: part)
        }
    }
}

// MARK: - Helpers

private enum ModelSession {
    /// Ephemeral: nothing is cached or stored by URLSession.
    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 8
        return config
    }
}

private enum ContentRange {
    /// "bytes 0-0/127759464" → 127759464
    static func total(from header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// "bytes 100-199/1000" → 100
    static func start(from header: String?) -> Int64? {
        guard let header else { return nil }
        let afterUnit = header.drop(while: { !$0.isNumber })
        return Int64(afterUnit.prefix(while: { $0.isNumber }))
    }
}
