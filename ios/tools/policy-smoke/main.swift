import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}
func rejects(_ message: String, _ work: () throws -> Void) {
    do { try work(); fatalError("Expected rejection: " + message) }
    catch { checks += 1 }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
for ext in OfflineMediaPolicy.extensions {
    check(OfflineMediaPolicy.supports(name: "中文 a+b%." + ext, size: 4, contentType: "video/unknown"), ext)
    let file = root.appendingPathComponent("sample." + ext)
    try Data([1, 2, 3, 4]).write(to: file)
    try OfflineMediaPolicy.validateLocalFile(file)
    checks += 1
}
for ext in ["m3u8", "mpd", "m3u", "pls", "zip", "html"] {
    check(!OfflineMediaPolicy.supports(name: "a." + ext, size: 100, contentType: "video/mp4"), ext)
}
for url in ["https://example.com/a.mp4", "http://127.0.0.1/a.mp4", "file://remote-host/a.mp4"] {
    rejects(url) { try OfflineMediaPolicy.validateLocalFile(URL(string: url)!) }
}
let file = root.appendingPathComponent("fake.mp4")
for text in ["#EXTM3U\nhttp://host/a.ts", "[playlist]", "\u{feff}\n #EXTM3U", "<MPD/>", "<?xml?><MPD/>", "<html>bad</html>", "{\"error\":1}"] {
    try Data(text.utf8).write(to: file)
    rejects(text) { try OfflineMediaPolicy.validateLocalFile(file) }
}
try Data().write(to: file)
rejects("empty") { try OfflineMediaPolicy.validateLocalFile(file) }
try FileManager.default.removeItem(at: file)
rejects("missing") { try OfflineMediaPolicy.validateLocalFile(file) }
check(PlaybackPosition.resume(saved: 25, duration: 100) == 25, "resume")
for value in [0.0, -1, 99, .nan, .infinity] {
    check(PlaybackPosition.resume(saved: value, duration: 100) == nil, "bad resume")
}
check(PlaybackPosition.clamp(-15, duration: 100) == 0, "negative seek")
check(PlaybackPosition.clamp(200, duration: 100) == 99.9, "end seek")
check(PlaybackPosition.clamp(.nan, duration: 100) == nil, "nan seek")
check(PlaybackPosition.label(3661) == "1:01:01", "duration")
check(PlaybackPosition.label(.infinity) == "00:00", "infinite duration")
print("PASS: \(checks) offline policy assertions")
