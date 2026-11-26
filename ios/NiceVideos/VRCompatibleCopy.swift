import AVFoundation
import Darwin
import Foundation

enum VRCompatibleCopy {
    @MainActor
    static func generate(fileURL: URL, pickedFile: PickedVideoFile?, destination: URL,
                         onProgress: @escaping (Double) -> Void) async throws -> URL {
        guard fileURL.isFileURL, destination.isFileURL, destination.pathExtension.lowercased() == "mp4",
              fileURL.standardizedFileURL != destination.standardizedFileURL else {
            throw ClientError("请选择新的 MP4 副本位置。")
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try Task.checkCancellation()
        let input: PickedVideoFile
        if let pickedFile {
            guard pickedFile.url == fileURL else { throw ClientError("原片与选中的文件不一致。") }
            input = pickedFile
        } else {
            input = try await PickedVideoFile.open(fileURL)
        }
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: folder) }
        let staging = folder.appendingPathComponent("movie.mp4")
        let converter = NICEVLCOfflineTranscoder()
        let loader = PickedAssetResourceLoader(file: input)
        defer { loader.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // Reading track metadata does not require the device to decode
            // 8K HEVC. Keep the packed eye layout and SDR appearance intact.
            let asset = loader.asset
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw ClientError("未能读取原片的视频轨信息。请选择单视频轨、左右分屏的 SDR 影片。")
            }
            let transform = try await video.load(.preferredTransform)
            guard transform.isIdentity else {
                throw ClientError("原片带有旋转或镜像标记，当前转换器支持正向存储的左右分屏影片。")
            }
            for format in try await video.load(.formatDescriptions) {
                let tags = CMFormatDescriptionGetExtensions(format) as? [String: Any]
                let transfer = tags?[kCVImageBufferTransferFunctionKey as String] as? String
                let codec = CMFormatDescriptionGetMediaSubType(format)
                if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ||
                    transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ||
                    codec == 0x64766831 || codec == 0x64766865 { // dvh1 / dvhe
                    throw ClientError("当前手机转换器支持 SDR 影片。这部影片需要 HDR 色调映射。")
                }
            }
            let packedSize = try await video.load(.naturalSize)
            guard packedSize.width.isFinite, packedSize.height.isFinite,
                  packedSize.width > 0, packedSize.height > 0 else { throw ClientError("未能读取原片的尺寸。") }
            let scale = min(1, 1920 / max(packedSize.width, packedSize.height))
            let width = UInt32(max(2, (packedSize.width * scale / 2).rounded() * 2))
            let sourceDuration = (try? await asset.load(.duration))?.seconds ?? 0
            let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
            try Task.checkCancellation()
            onProgress(0)

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        let fd = Darwin.open(staging.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        defer { Darwin.close(fd) }
                        let failure = converter.run(byteCount: input.byteCount, outputFD: fd, width: width,
                            read: { buffer, count, offset in
                                (try? input.read(into: buffer, count: count, at: offset)) ?? -1
                            }, progress: { fraction in
                                DispatchQueue.main.async { if !converter.cancelled { onProgress(fraction) } }
                            })
                        if converter.cancelled { throw CancellationError() }
                        if let failure { throw ClientError(failure) }
                    })
                }
            }
            try Task.checkCancellation()
            do {
                try await validate(staging, sourceDuration: sourceDuration > 0 ? sourceDuration : converter.sourceSeconds,
                                   needsAudio: converter.sourceHasAudio || audioTracks?.isEmpty == false)
            } catch {
                try Task.checkCancellation()
                if let free = try? staging.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
                   free < 8 * 1024 * 1024 { throw ClientError("iPhone 的可用空间不足，副本未完整写入。") }
                throw error
            }
            try Task.checkCancellation()
            let output = try await Task.detached(priority: .userInitiated) {
                try publish(staging, to: destination, converter: converter)
            }.value
            onProgress(1)
            return output
        } onCancel: {
            converter.cancel()
            loader.cancel()
        }
    }

    private static func validate(_ url: URL, sourceDuration: Double, needsAudio: Bool) async throws {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              try await video.load(.isDecodable),
              let description = try await video.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264 else {
            throw ClientError("转换器未生成可由系统解码的 H.264 视频。")
        }
        let duration = try await asset.load(.duration).seconds
        let videoDuration = try await video.load(.timeRange).duration.seconds
        let tolerance = min(2, max(0.25, sourceDuration * 0.01))
        guard duration.isFinite, duration > 0, videoDuration.isFinite, videoDuration > 0,
              sourceDuration.isFinite, sourceDuration > 0, abs(duration - sourceDuration) <= tolerance,
              videoDuration >= sourceDuration - tolerance else {
            throw ClientError("副本的视频时长与原片不符，可能没有完整转换。")
        }
        if needsAudio {
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
                  try await audio.load(.isDecodable) else { throw ClientError("副本缺少原片的可播放音轨。") }
        }
        let images = AVAssetImageGenerator(asset: asset)
        images.maximumSize = CGSize(width: 64, height: 64)
        images.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        images.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        for second in [videoDuration * 0.1, videoDuration * 0.9] {
            try Task.checkCancellation()
            _ = try await images.image(at: CMTime(seconds: second, preferredTimescale: 600))
        }
    }

    private static func publish(_ staging: URL, to target: URL, converter: NICEVLCOfflineTranscoder) throws -> URL {
        // File providers can remap a directory during coordination. Keep the
        // staging copy on the destination volume for an exclusive final rename.
        let manager = FileManager.default
        let requestedDirectory = target.deletingLastPathComponent()
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Result<URL, Error>?
        coordinator.coordinate(writingItemAt: requestedDirectory, options: .forMerging, error: &coordinationError) { directory in
            outcome = Result {
                guard !converter.cancelled else { throw CancellationError() }
                let destination = directory.appendingPathComponent(target.lastPathComponent)
                guard !manager.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                // On local storage this publishes by one rename, with no
                // second copy of a potentially large movie.
                if Darwin.renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return target }
                if errno == EEXIST { throw CocoaError(.fileWriteFileExists) }
                let partial = directory.appendingPathComponent(".nicevr-\(UUID().uuidString).part")
                let fd = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { try? manager.removeItem(at: partial) }
                let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                let reader = try FileHandle(forReadingFrom: staging)
                defer { try? reader.close(); try? writer.close() }
                while !converter.cancelled, let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try writer.write(contentsOf: data)
                }
                try writer.synchronize()
                guard !converter.cancelled else { throw CancellationError() }
                guard Darwin.renamex_np(partial.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return target
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        return try outcome.get()
    }
}
