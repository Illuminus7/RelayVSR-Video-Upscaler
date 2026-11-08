import AVFoundation
import Foundation

/// What the app needs to know about the input video. Reading it also checks that the
/// file is a video macOS can open (MP4, MOV, M4V), which the final assembly step needs.
struct VideoInfo: Sendable, Equatable {
    /// Encoded frame size (before rotation). The pixel count drives the memory estimate.
    let width: Int
    let height: Int
    let fps: Double
    let frameCount: Int
    let duration: Double
    /// Where the video track starts on the file's timeline, for keeping audio in sync.
    let videoStart: Double
    let transform: CGAffineTransform
    let hasAudio: Bool

    /// Size as it is shown, with rotation applied.
    var displaySize: CGSize {
        let rect = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    static func load(_ url: URL) async throws -> VideoInfo {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            throw AppError("“\(url.lastPathComponent)” is not a video file.")
        }
        let asset = AVURLAsset(url: url)
        let unreadable = AppError("“\(url.lastPathComponent)” can't be read. Use an MP4, MOV or M4V video.")
        guard let track = (try? await asset.loadTracks(withMediaType: .video))?.first else { throw unreadable }
        guard let (size, rate, transform, range) = try? await track.load(.naturalSize, .nominalFrameRate,
                                                                         .preferredTransform, .timeRange) else {
            throw unreadable
        }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let duration = range.duration.seconds
        guard size.width >= 1, size.height >= 1, rate > 0, duration.isFinite, duration > 0 else { throw unreadable }
        let fps = Double(rate)
        return VideoInfo(width: Int(size.width), height: Int(size.height), fps: fps,
                         frameCount: max(1, Int((duration * fps).rounded())), duration: duration,
                         videoStart: range.start.seconds.isFinite ? range.start.seconds : 0,
                         transform: transform, hasAudio: !audio.isEmpty)
    }
}

/// How many frames go into one part. The engine decodes every frame of a part at the
/// upscaled size on the GPU, so a whole long video does not fit; it is upscaled part by part.
///
/// Calibrated on a 48 GB M-series Mac with PyTorch 2.14.1. Parts tried, all of which fit:
/// 1920×1080 at ×2, 60 frames; 1920×1080 at ×4, 8 frames; 512×768 at ×4, 90 frames. The constants
/// stay under those. A part that still runs out of memory is retried at half the size
/// (see `Upscaler`).
enum PartSizing {
    /// PyTorch lets the GPU use about 78% of memory; the model and decoder take about 7 GB of that.
    static func availableBytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Double {
        Double(physicalMemory) * 0.78 - 7e9
    }

    /// Fixed working memory per upscaled pixel while one frame is decoded.
    static let workingBytesPerPixel = 700.0
    /// Memory per upscaled pixel for every frame held in a part.
    static let heldBytesPerPixel = 48.0

    static func initialFrames(for info: VideoInfo, scale: Scale,
                              physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws -> Int {
        let outPixels = Double(info.width * info.height * scale.rawValue * scale.rawValue)
        let available = availableBytes(physicalMemory: physicalMemory)
        // Refuse only when even one frame is clearly out of reach; near the limit, try one frame
        // per part and let the engine decide.
        guard outPixels * workingBytesPerPixel < available * 1.5 else {
            throw tooLarge(info: info, scale: scale, available: available)
        }
        let room = available - outPixels * workingBytesPerPixel
        var frames = Int(max(0, room) / (outPixels * heldBytesPerPixel))
        frames = min(frames, 120)
        if frames >= 30 { frames = frames / 15 * 15 }   // RelayVSR keys on every 15th frame
        return max(1, frames)
    }

    /// Start time of the part that begins at `frame`. Boundaries sit halfway between frames,
    /// so every frame lands in exactly one part even with rounding.
    static func time(ofFrame frame: Int, fps: Double) -> Double {
        frame == 0 ? 0 : (Double(frame) - 0.5) / fps
    }

    static func tooLarge(info: VideoInfo, scale: Scale, available: Double = availableBytes()) -> AppError {
        // Largest input the estimate allows, as a 16:9 example.
        let maxOutPixels = available * 1.5 / workingBytesPerPixel
        let maxInPixels = maxOutPixels / Double(scale.rawValue * scale.rawValue)
        let height = Int((maxInPixels * 9 / 16).squareRoot())
        let width = height * 16 / 9
        return AppError("A \(info.width)×\(info.height) video needs more memory than this Mac has at ×\(scale.rawValue). "
                        + "At ×\(scale.rawValue) this Mac can take videos up to about \(width)×\(height).")
    }
}

/// Joins the upscaled parts into one MP4 and adds the original audio. The video is never
/// re-encoded. The audio is copied as well when MP4 can hold it (AAC, ALAC, MP3…); audio MP4
/// can't hold, such as the uncompressed PCM in many MOV files, is converted to AAC.
enum VideoAssembler {
    static func assemble(parts: [URL], source: URL, info: VideoInfo, scale: Scale, to destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError("Could not prepare the output video.")
        }
        var cursor = CMTime.zero
        for url in parts {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw AppError("An upscaled part has no video.")
            }
            let range = try await track.load(.timeRange)
            try videoTrack.insertTimeRange(range, of: track, at: cursor)
            cursor = cursor + range.duration
        }

        // No rotation is set here: the engine applies the source's rotation when it decodes the
        // frames, so the parts are already upright.

        if info.hasAudio {
            let original = AVURLAsset(url: source)
            if let audio = try await original.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await audio.load(.timeRange)
                let offset = CMTime(seconds: max(0, range.start.seconds - info.videoStart), preferredTimescale: 600)
                let length = CMTimeMinimum(range.duration, CMTimeSubtract(cursor, offset))
                if length > .zero {
                    try audioTrack.insertTimeRange(CMTimeRange(start: range.start, duration: length), of: audio, at: offset)
                }
            }
        }

        let copiesIntoMP4 = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                                     with: composition, outputFileType: .mp4)
        if copiesIntoMP4, try await audioPlaysInMP4(composition) {
            try await copyAll(composition, to: destination)
        } else {
            try await copyVideoConvertingAudio(composition, to: destination)
        }
    }

    /// Audio formats players expect in an MP4. macOS will also write uncompressed PCM into an
    /// MP4, but many players can't play that, so PCM (and anything else) is converted.
    private static let mp4AudioFormats: Set<AudioFormatID> = [
        kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
        kAudioFormatMPEGLayer3, kAudioFormatAC3, kAudioFormatEnhancedAC3,
        kAudioFormatAppleLossless, kAudioFormatOpus, kAudioFormatFLAC,
    ]

    private static func audioPlaysInMP4(_ composition: AVComposition) async throws -> Bool {
        guard let track = try await composition.loadTracks(withMediaType: .audio).first else { return true }
        let formats = try await track.load(.formatDescriptions)
        return !formats.isEmpty && formats.allSatisfy { mp4AudioFormats.contains(CMFormatDescriptionGetMediaSubType($0)) }
    }

    /// Everything is copied as it is.
    private static func copyAll(_ composition: AVComposition, to destination: URL) async throws {
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AppError("Could not prepare the output video.")
        }
        try await withTaskCancellationHandler {
            if #available(macOS 15, *) {
                try await export.export(to: destination, as: .mp4)
            } else {
                export.outputURL = destination
                export.outputFileType = .mp4
                await export.export()
                if let error = export.error { throw error }
                guard export.status == .completed else { throw CancellationError() }
            }
        } onCancel: {
            export.cancelExport()
        }
    }

    /// The video samples are copied as they are; the audio is decoded and written as AAC.
    private static func copyVideoConvertingAudio(_ composition: AVComposition, to destination: URL) async throws {
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)

        guard let videoTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw AppError("Could not prepare the output video.")
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        reader.add(videoOutput)
        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        writer.add(videoInput)

        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        if let audioTrack = try await composition.loadTracks(withMediaType: .audio).first {
            let format = try await audioTrack.load(.formatDescriptions).first
            let description = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            // AAC is written at 44.1 or 48 kHz, where the bitrate below is valid; any other rate
            // (32 kHz, 96 kHz…) is resampled to 48 kHz on the way. At 32 kHz, for example, AAC
            // can't reach 192 kbps stereo and the writer fails with "Cannot Encode Media".
            let sampleRate = description?.mSampleRate == 44_100 ? 44_100.0 : 48_000.0
            let channels = description?.mChannelsPerFrame == 1 ? 1 : 2   // stereo, mixed down if needed
            let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                                      AVSampleRateKey: sampleRate,
                                      AVNumberOfChannelsKey: channels]
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: pcm)
            reader.add(audioOutput)
            let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                      AVSampleRateKey: sampleRate,
                                      AVNumberOfChannelsKey: channels,
                                      AVEncoderBitRateKey: channels == 1 ? 96_000 : 192_000]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            writer.add(audioInput)
            audioPair = (audioOutput, audioInput)
        }

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? AppError("Could not write the output video.")
        }
        writer.startSession(atSourceTime: .zero)

        try await withTaskCancellationHandler {
            async let video: Void = pump(videoOutput, into: videoInput, label: "video")
            if let (audioOutput, audioInput) = audioPair {
                await pump(audioOutput, into: audioInput, label: "audio")
            }
            await video
            try Task.checkCancellation()
            if let error = reader.error ?? writer.error { throw error }
            await writer.finishWriting()
            if let error = writer.error { throw error }
        } onCancel: {
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    /// Feeds one reader output into one writer input until the output runs dry.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String) async {
        let queue = DispatchQueue(label: "RelayVSR.assemble.\(label)")
        // Both are used only on `queue`, one callback at a time.
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if let sample = output.copyNextSampleBuffer(), input.append(sample) {
                        continue
                    }
                    finished = true
                    input.markAsFinished()
                    continuation.resume()
                }
            }
        }
    }
}
