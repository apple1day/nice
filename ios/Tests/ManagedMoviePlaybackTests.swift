import AVFoundation
import Metal
import UIKit
import XCTest
@testable import NiceVideos

@MainActor
final class ManagedMoviePlaybackTests: XCTestCase {
    private let vr180 = SBSDisplayMode.immersive(.vr180, .sideBySide, headset: false)

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    // Exercise the hashed download on disk and the real watched/playlist wrapper.
    // A Files picker request uses a different engine construction path.
    private func withDownloadedMovie(_ source: URL, run: (PlaylistPlaybackModel, SBSPlaybackView, URL) async throws -> Void) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let disk = try LocalStorage(root: root)
        defer { try? fm.removeItem(at: root) }
        let size = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let video = Video(name: "downloaded.mp4", size: Int64(size), contentType: "video/mp4",
                          url: "/unused", downloadUrl: "/unused")
        var record = DownloadRecord(video: video, server: try ServerAddress.normalize("http://127.0.0.1:9"))
        record.state = .complete
        let url = try disk.destination(for: record)
        try fm.copyItem(at: source, to: url)
        try disk.saveRecords([record])
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VideoStore(storage: disk, defaults: defaults, restoreDownloads: false)
        store.playLocal(record)
        let request = try XCTUnwrap(store.playback)
        XCTAssertNil(request.pickedFile)
        let playlist = PlaylistPlaybackModel(request: request, store: store, defaults: defaults, manageAudioSession: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 240))
        let controller = UIViewController()
        window.rootViewController = controller
        let host = SBSPlaybackView(frame: window.bounds)
        controller.view.addSubview(host)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { playlist.close(); window.isHidden = true }
        host.mode = vr180
        playlist.player.attach(to: host)
        try await run(playlist, host, url)
    }

    private func waitFor(_ description: String, until condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(14)
        while try !condition() {
            if Date() >= deadline { throw NSError(domain: "ManagedMoviePlaybackTests", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: description]) }
            try await Task.sleep(nanoseconds: 70_000_000)
        }
    }

    func testDownloadedMP4UsesOneSystemItemInVR180AndOrdinaryPlayback() async throws {
        try await withDownloadedMovie(fixture("panorama-audio", "mp4")) { playlist, host, _ in
            let layer = try XCTUnwrap(host.drawableView.subviews.compactMap { $0.layer as? AVPlayerLayer }.first,
                                      "A downloaded MP4 should open in AVPlayer by default")
            let player = try XCTUnwrap(layer.player)
            let originalItem = try XCTUnwrap(player.currentItem)
            let renderer = try XCTUnwrap(host.renderer)
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                       width: 64, height: 32, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .renderTarget
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store

            // The reported movie had only its first frame after five seconds.
            // Here the left-eye chart's blue channel alternates every second.
            try await waitFor("Playback did not reach 5 s") { playlist.player.seconds >= 5 }
            var sampled = renderer.acceptedFrameID
            var minBlue = 255, maxBlue = 0
            try await waitFor("The projected picture did not change beyond the first five seconds") {
                guard renderer.acceptedFrameID > sampled else { return false }
                sampled = renderer.acceptedFrameID
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(renderer.encodeMovie(pass: pass, command: command))
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes {
                    target.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(32, 16, 1, 1), mipmapLevel: 0)
                }
                minBlue = min(minBlue, Int(pixel[0]))
                maxBlue = max(maxBlue, Int(pixel[0]))
                return maxBlue - minBlue > 20
            }
            XCTAssertEqual(playlist.player.videoOutput, .system)
            let before = player.currentTime().seconds
            host.mode = .standard
            XCTAssertNil(host.renderer)
            host.mode = self.vr180
            try await self.waitFor("Switching back to VR did not produce fresh frames") {
                (host.renderer?.acceptedFrameID ?? 0) >= 2
            }
            XCTAssertTrue(player.currentItem === originalItem)
            let newLayer = try XCTUnwrap(host.drawableView.subviews.compactMap { $0.layer as? AVPlayerLayer }.first)
            XCTAssertTrue(newLayer.player === player)
            XCTAssertGreaterThanOrEqual(player.currentTime().seconds, before - 0.25)

            let lastSystemFrame = host.renderer?.acceptedFrameID ?? 0
            host.configure(mode: self.vr180, standardOutput: .vlcFrames)
            try await self.waitFor("Explicit VLC selection failed to deliver video") {
                playlist.player.videoOutput == .vlcFrames && playlist.player.seconds >= before - 0.25 &&
                    (host.renderer?.acceptedFrameID ?? 0) >= lastSystemFrame + 3
            }
        }
    }

    func testManagedFallbackCanRetrySystemFromThePlaylistPlayer() async throws {
        try await withDownloadedMovie(fixture("offline", "mkv")) { playlist, host, url in
            try await self.waitFor("Expected the incompatible MP4 payload to fall back to VLC frames") {
                playlist.player.videoOutput == .vlcFrames && (host.renderer?.acceptedFrameID ?? 0) >= 1
            }
            playlist.player.pause()
            // A now-compatible copy lets the test observe a successful retry.
            // The selected output in the view stays .system across automatic fallback.
            let bytes = try Data(contentsOf: self.fixture("panorama-audio", "mp4"))
            try bytes.write(to: url, options: .atomic)
            playlist.player.prepareOutputChange(to: .system)
            host.configure(mode: self.vr180, standardOutput: .system)
            try await self.waitFor("The managed playlist did not retry AVPlayer") {
                playlist.player.videoOutput == .system &&
                    host.drawableView.subviews.contains { ($0.layer as? AVPlayerLayer)?.player?.currentItem != nil }
            }
        }
    }
}
