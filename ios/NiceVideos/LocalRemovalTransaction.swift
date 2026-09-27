import Foundation

// The index is the commit point. Move within Application Support before writing it,
// so a failed index write can restore the file instead of losing the user's video.
// This helper has no URLSession, server URL or decoder dependency.
enum LocalRemovalTransaction {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let fm = FileManager.default

    static func itemType(at url: URL) throws -> FileAttributeType? {
        do { return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
        catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
            throw error
        }
    }

    // nil means all disk space was reclaimed. A warning means the index committed,
    // but unlinking the staged file must be retried before a new download of this ID.
    static func commit(file: URL, staged: URL, writeIndex: () throws -> Void) throws -> String? {
        let directory = staged.deletingLastPathComponent()
        if let type = try itemType(at: directory) {
            guard type == .typeDirectory else {
                throw Failure(message: "删除暂存目录异常；已停止操作，未删除视频。")
            }
        } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard try itemType(at: staged) == nil else {
            throw Failure(message: "有未完成的文件删除，请关闭并重新打开 App 后重试。")
        }
        let type = try itemType(at: file)
        guard type == nil || type == .typeRegular else {
            throw Failure(message: "视频路径不是普通文件，已停止删除。")
        }
        let moved = type != nil
        if moved { try fm.moveItem(at: file, to: staged) }
        do { try writeIndex() }
        catch {
            let indexError = error
            if moved {
                do { try fm.moveItem(at: staged, to: file) }
                catch {
                    throw Failure(message: "索引保存失败，视频已保留在删除暂存目录。请重启 App 恢复。\n\(indexError.localizedDescription)\n\(error.localizedDescription)")
                }
            }
            throw indexError
        }
        if moved {
            do { try fm.removeItem(at: staged) }
            catch { return "记录已删除，但空间暂未完全释放；重启 App 后会重试清理：\(error.localizedDescription)" }
        }
        return nil
    }

    // After a crash: a referenced file was staged BEFORE commit, so restore it;
    // an unreferenced file was staged AFTER an authorized deletion, so finish it.
    static func recover(file: URL, staged: URL, isReferenced: Bool) throws {
        guard let type = try itemType(at: staged) else { return }
        guard type == .typeRegular else {
            throw Failure(message: "删除暂存项不是普通文件，已保留并停止自动处理。")
        }
        if isReferenced {
            guard try itemType(at: file) == nil else {
                throw Failure(message: "原文件与待恢复文件同时存在，已保留两份文件，请勿卸载 App。")
            }
            try fm.moveItem(at: staged, to: file)
        } else { try fm.removeItem(at: staged) }
    }
}
