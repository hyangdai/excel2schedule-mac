import Foundation
import CryptoKit

/// Style-independent undo information shared by the live Excel and closed-file writers.
/// A character flag uses Excel's character indexing, recorded together with its text.
enum CompletionStrikeStore {
    struct Original: Codable, Equatable {
        var text: String
        var flags: [Bool]
    }
    static func folder(sourcePath: String, storage: URL) -> URL {
        let key = SHA256.hash(data: Data(sourcePath.utf8)).map { String(format: "%02x", $0) }.joined()
        return storage.appendingPathComponent("excel-writeback/" + key, isDirectory: true)
    }
    static func load(sourcePath: String, storage: URL) throws -> [String: Original] {
        let file = folder(sourcePath: sourcePath, storage: storage).appendingPathComponent("live-marks.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: Original].self, from: Data(contentsOf: file))
    }
    static func save(_ originals: [String: Original], sourcePath: String, storage: URL) throws {
        let directory = folder(sourcePath: sourcePath, storage: storage)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(originals).write(to: directory.appendingPathComponent("live-marks.json"), options: .atomic)
    }
    static func utf16Flags(text: String, flags: [Bool]) throws -> [Bool] {
        if text.utf16.count == flags.count { return flags }
        let scalars = Array(text.unicodeScalars)
        if scalars.count == flags.count {
            return zip(scalars, flags).flatMap { Array(repeating: $0.1, count: String($0.0).utf16.count) }
        }
        let characters = Array(text)
        if characters.count == flags.count {
            return zip(characters, flags).flatMap { Array(repeating: $0.1, count: String($0.0).utf16.count) }
        }
        throw WorkbookError.invalid("文字的字符计数不一致，暂缓同步以保留原格式。")
    }
}
