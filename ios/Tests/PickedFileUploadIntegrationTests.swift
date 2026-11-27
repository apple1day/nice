import XCTest
import Combine
import Network
@testable import NiceVideos

// Exercise URLSessionUploadTask's actual file body on loopback. URLProtocol
// mocks can manufacture a receipt without ever reading the uploaded file.
private final class UploadReceiver {
    private let queue = DispatchQueue(label: "NiceVideosTests.uploadReceiver")
    private let listener: NWListener
    private var received: [(String, Data)] = []
    var requests: [(String, Data)] { queue.sync { received } }

    init() throws {
        let tcp = NWParameters.tcp
        tcp.requiredInterfaceType = .loopback
        listener = try NWListener(using: tcp)
    }

    func start(_ ready: XCTestExpectation) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.fulfill()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue)
            receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    var url: URL? { listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)") } }
    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, complete, error in
            guard let self, error == nil, let chunk, !chunk.isEmpty else { connection.cancel(); return }
            var message = accumulated
            message.append(chunk)
            if message.count > 256 * 1024 { connection.cancel(); return }
            if let boundary = message.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: message[..<boundary.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let fields = lines.dropFirst().compactMap { line -> (String, String)? in
                    guard let colon = line.firstIndex(of: ":") else { return nil }
                    return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
                let headers = Dictionary(fields, uniquingKeysWith: { first, _ in first })
                guard let length = headers["content-length"].flatMap(Int.init), length >= 0,
                      let target = lines[0].split(separator: " ").dropFirst().first,
                      lines[0].hasPrefix("POST "),
                      let components = URLComponents(string: String(target)), components.path == "/api/upload-file",
                      let name = components.queryItems?.first(where: { $0.name == "name" })?.value,
                      let id = headers["x-nice-upload-id"], UUID(uuidString: id) != nil,
                      headers["x-nice-upload-bytes"] == String(length) else {
                    connection.cancel()
                    return
                }
                let bytes = message[boundary.upperBound...]
                if bytes.count == length {
                    let conflict = received.contains { $0.0 == name }
                    received.append((name, Data(bytes)))
                    let json = (try? JSONSerialization.data(withJSONObject: [
                        "version": 1, "uploadID": id, "name": name, "size": bytes.count
                    ])) ?? Data()
                    let status = conflict ? "409 Conflict" : "201 Created"
                    var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
                    response.append(json)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete { connection.cancel(); return }
            receive(connection, accumulated: message)
        }
    }
}

@MainActor final class PickedFileUploadIntegrationTests: XCTestCase {
    func testPickedFilesSendOriginalBytesAndSameBasenameReportsConflict() async throws {
        let receiver = try UploadReceiver()
        defer { receiver.stop() }
        let ready = expectation(description: "Local receiver is listening")
        receiver.start(ready)
        await fulfillment(of: [ready], timeout: 10)
        let server = try XCTUnwrap(receiver.url)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sbs", withExtension: "mp4", subdirectory: "Fixtures"))
        let firstBytes = try Data(contentsOf: movie)
        var secondBytes = firstBytes
        secondBytes.append(0)
        let name = "我的 VR + 50%#.mp4"
        func write(_ bytes: Data, folder: String) throws -> URL {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            try bytes.write(to: file)
            return file
        }
        let first = try write(firstBytes, folder: "Files-A")
        let second = try write(secondBytes, folder: "Files-B")
        let manager = LocalUploadManager(root: root.appendingPathComponent("jobs"), configuration: .ephemeral, resolveSource: { _ in
            XCTFail("A Files selection must not consult downloaded-library records")
            throw LocalUploadError("Unexpected download source")
        })
        defer { manager.invalidate() }

        let selected = try await LocalUploadSource.pickedFiles([first, second])
        XCTAssertEqual(selected.count, 2)
        let finished = expectation(description: "Sequential submissions have terminal outcomes")
        let subscription = manager.$jobs.first { $0.count == 2 && $0.allSatisfy { !$0.state.isPending } }
            .sink { _ in finished.fulfill() }
        defer { subscription.cancel() }
        XCTAssertTrue(manager.enqueue(selected, server: server, allowsCellular: false))
        await fulfillment(of: [finished], timeout: 15)

        XCTAssertEqual(manager.jobs.map(\.state), [.completed, .conflict], manager.jobs.compactMap(\.message).joined(separator: "\n"))
        let read = receiver.requests
        XCTAssertEqual(read.map { $0.0 }, [name, name])
        XCTAssertEqual(read.map { $0.1 }, [firstBytes, secondBytes])
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
    }
}
