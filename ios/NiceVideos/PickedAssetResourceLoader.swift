import AVFoundation
import UniformTypeIdentifiers

/// Serves a single, already-open Files document to AVFoundation. The player
/// retains this object for as long as its asset can request bytes.
final class PickedAssetResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let file: PickedVideoFile
    private let contentType: String
    private let delegateQueue = DispatchQueue(label: "NiceVideos.Files.asset.requests", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "NiceVideos.Files.asset.read", qos: .userInitiated)

    // All request state belongs to delegateQueue. Keep at most one allocated
    // chunk being read, even if AVFoundation issues overlapping seek requests.
    static let chunkSize = 512 * 1024
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var reading = false
    private var cancelled = false

    init(file: PickedVideoFile) {
        self.file = file
        let ext = file.url.pathExtension.lowercased()
        contentType = (UTType(filenameExtension: ext) ?? .movie).identifier
        let url = URL(string: "nice-picked://document")!
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue
        ])
        super.init()
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !cancelled, request.request.url == asset.url else { return false }
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(file.byteCount)
            info.isByteRangeAccessSupported = true
        }
        if request.dataRequest == nil {
            request.finishLoading()
        } else {
            pending.append(request)
            pump()
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
    }

    /// Let an outstanding provider read return on its own queue. Once cancelled,
    /// its completion must never respond to the abandoned AVFoundation request.
    func cancel() {
        delegateQueue.async {
            guard !self.cancelled else { return }
            self.cancelled = true
            let requests = self.pending
            self.pending.removeAll()
            for request in requests where !request.isCancelled && !request.isFinished {
                request.finishLoading(with: URLError(.cancelled))
            }
        }
    }

    /// AVFoundation can request a range extending beyond EOF, or all remaining
    /// data. Limit before adding offsets, including for an Int.max length.
    static func nextChunk(requestedOffset: Int64, currentOffset: Int64, length: Int,
                          toEnd: Bool, fileLength: Int64) throws -> Range<Int64>? {
        guard requestedOffset >= 0, currentOffset >= 0, length >= 0 else { throw POSIXError(.EINVAL) }
        guard requestedOffset < fileLength else { return nil }
        let end = toEnd ? fileLength : requestedOffset + min(fileLength - requestedOffset, Int64(length))
        let offset = max(requestedOffset, currentOffset)
        guard offset < end else { return nil }
        return offset..<(offset + min(end - offset, Int64(chunkSize)))
    }

    private func pump() {
        guard !reading, !cancelled else { return }
        while let request = pending.first {
            guard !request.isCancelled, !request.isFinished, let dataRequest = request.dataRequest else {
                pending.removeFirst()
                continue
            }
            let range: Range<Int64>
            do {
                guard let next = try Self.nextChunk(requestedOffset: dataRequest.requestedOffset,
                    currentOffset: dataRequest.currentOffset, length: dataRequest.requestedLength,
                    toEnd: dataRequest.requestsAllDataToEndOfResource, fileLength: Int64(file.byteCount)) else {
                    pending.removeFirst()
                    request.finishLoading()
                    continue
                }
                range = next
            } catch {
                pending.removeFirst()
                request.finishLoading(with: error)
                continue
            }

            reading = true
            readQueue.async { [self] in
                let result = Result<Data, Error> {
                    var bytes = Data(count: Int(range.upperBound - range.lowerBound))
                    let count = try bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                        try file.read(into: buffer.baseAddress!, count: buffer.count, at: UInt64(range.lowerBound))
                    }
                    guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                    bytes.count = count
                    return bytes
                }
                delegateQueue.async {
                    self.reading = false
                    if let index = self.pending.firstIndex(where: { $0 === request }) {
                        self.pending.remove(at: index)
                        if !request.isCancelled && !request.isFinished {
                            switch result {
                            case .success(let bytes):
                                dataRequest.respond(with: bytes)
                                self.pending.append(request)
                            case .failure(let error):
                                request.finishLoading(with: error)
                            }
                        }
                    }
                    self.pump()
                }
            }
            return
        }
    }
}
