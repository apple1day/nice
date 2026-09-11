import Foundation

var assertions = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    assertions += 1
}
func expectFailure(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError(label) } catch { assertions += 1 }
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let video = root.appendingPathComponent("video.mp4")
let staged = root.appendingPathComponent("RemovalStaging/video.mp4")
let bytes = Data([0, 1, 2, 3])
try bytes.write(to: video)
let warning = try LocalRemovalTransaction.commit(file: video, staged: staged) {
    check(!fm.fileExists(atPath: video.path), "stage before index write")
    check(fm.fileExists(atPath: staged.path), "recoverable file exists before commit")
}
check(warning == nil, "no cleanup failure")
check(!fm.fileExists(atPath: video.path), "file removed")
check(!fm.fileExists(atPath: staged.path), "staged file removed")
try bytes.write(to: video)
expectFailure("index write must throw") {
    _ = try LocalRemovalTransaction.commit(file: video, staged: staged) {
        throw LocalRemovalTransaction.Failure(message: "simulated disk full")
    }
}
check(try! Data(contentsOf: video) == bytes, "rollback restores original bytes")
check(!fm.fileExists(atPath: staged.path), "rollback consumes stage")
try fm.moveItem(at: video, to: staged)
try LocalRemovalTransaction.recover(file: video, staged: staged, isReferenced: true)
check(try! Data(contentsOf: video) == bytes, "crash before commit restores original")
try fm.moveItem(at: video, to: staged)
try LocalRemovalTransaction.recover(file: video, staged: staged, isReferenced: false)
check(!fm.fileExists(atPath: staged.path), "crash after commit reclaims disk")
var committed = false
_ = try LocalRemovalTransaction.commit(file: video, staged: staged) { committed = true }
check(committed, "missing file can still remove stale record")
try fm.createDirectory(at: video, withIntermediateDirectories: true)
expectFailure("never delete directories recursively") {
    _ = try LocalRemovalTransaction.commit(file: video, staged: staged) { fatalError("must not write") }
}
check(fm.fileExists(atPath: video.path), "directory preserved")
try fm.removeItem(at: video)
try bytes.write(to: video)
try bytes.write(to: staged)
expectFailure("never overwrite staging") {
    _ = try LocalRemovalTransaction.commit(file: video, staged: staged) { fatalError("must not write") }
}
expectFailure("ambiguous recovery preserves both copies") {
    try LocalRemovalTransaction.recover(file: video, staged: staged, isReferenced: true)
}
check(fm.fileExists(atPath: video.path) && fm.fileExists(atPath: staged.path), "both copies retained")
try fm.removeItem(at: staged)
let link = root.appendingPathComponent("link.mp4")
try fm.createSymbolicLink(at: link, withDestinationURL: video)
expectFailure("symlink must not delete its target") {
    _ = try LocalRemovalTransaction.commit(file: link, staged: staged) { fatalError("must not write") }
}
check(try! Data(contentsOf: video) == bytes, "symlink target preserved")
print("Local removal transaction: \(assertions) assertions passed.")
