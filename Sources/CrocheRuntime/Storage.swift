import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// acquire must provide exclusive ownership until release. save must atomically replace
/// the whole JSON snapshot or throw; it must never be interrupted by cancellation.
public protocol RuntimeStorage: Sendable {
    func acquire() throws
    func load() throws -> JSON
    func save(_ state: JSON) throws
    func release()
    /// Deletes the snapshot for real; absence succeeds. Required, with no tombstone default.
    func remove() throws
}

/// A RuntimeStorage that also keeps named entries beside the snapshot, such as `held`: the sends
/// waiting behind a running turn (F19). Each entry is replaced atomically and independently of the
/// snapshot, under the same ownership. `load(entry:)` returns `.null` for an entry never saved.
/// A storage without entries still works; the Runtime then cannot keep sends that arrive while a
/// turn runs, and refuses them (`storage_error`) rather than overwrite the snapshot.
public protocol KeyedRuntimeStorage: RuntimeStorage {
    func load(entry: String) throws -> JSON
    func save(entry: String, _ value: JSON) throws
    /// Deletes an entry for real; absence succeeds.
    func remove(entry: String) throws
}

/// A RuntimeStorage that also keeps the turn archive (F20.6): every finished turn in full, as
/// JSON lines in entries named `archive<NNNN>` (100 turns each) beside the snapshot. Opt-in and
/// separate from KeyedRuntimeStorage: a storage without it keeps no archive, typed
/// (`archive_unavailable`), and everything else works. The Runtime keeps the rules (segments,
/// the byte bound, the last record per turn); the storage keeps lines:
/// - `appendLine` writes a newline first when the entry does not end with one, and is durable
///   when it returns;
/// - `readLines` returns complete lines only: a torn last line (a crash mid-append) is not one;
/// - `replaceLines` is atomic: after a crash the entry holds every old line or every new one,
///   never a mix and never none; `[]` deletes the entry;
/// - `remove` deletes for real; an absent entry is not an error;
/// - `entries` lists the entries whose names start with `prefix`, with their sizes in bytes.
public protocol ArchiveRuntimeStorage: RuntimeStorage {
    func appendLine(entry: String, _ line: String) throws
    func readLines(entry: String) throws -> [String]
    func replaceLines(entry: String, _ lines: [String]) throws
    func remove(entry: String) throws
    func entries(prefix: String) throws -> [String: Int]
}

/// Private local file storage with a process-safe advisory lock and atomic replacement.
/// Use an application-private directory; snapshots include runtime credentials. Entries are
/// sidecar files beside the snapshot (`<file>.held`), each replaced atomically. The turn archive
/// is sidecars too (`<file>.archive0001`, JSON lines), under the same lock; a segment is rewritten
/// to `<file>.archive0001.tmp-<nonce>` and renamed over it, and stale temporaries are deleted when
/// the storage is acquired.
public final class FileRuntimeStorage: KeyedRuntimeStorage, ArchiveRuntimeStorage, @unchecked Sendable {
    private let url: URL
    private let mutex = NSLock()
    private var descriptor: Int32 = -1
    /// Runs after a segment's temporary is complete and before the rename (tests inject a crash).
    var beforeCommit: ((URL) throws -> Void)?
    public init(url: URL) { self.url = url }
    public func acquire() throws {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor == -1 else { throw CrocheError("store_busy", "Storage is already owned") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CrocheError("storage_error", "Could not open storage lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd); throw CrocheError("store_busy", "Storage is already owned")
        }
        descriptor = fd
        removeStaleTemporaries()
    }
    public func load() throws -> JSON {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { throw CrocheError("storage_error", "Storage is not owned") }
        if !FileManager.default.fileExists(atPath: url.path) { return .null }
        let saved = try JSON(data: Data(contentsOf: url))
        guard saved.object != nil else { throw CrocheError("storage_error", "Existing Runtime snapshot must be an object") }
        return saved
    }
    public func save(_ state: JSON) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { throw CrocheError("storage_error", "Storage is not owned") }
        try state.encoded().write(to: url, options: .atomic)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
    }
    public func load(entry: String) throws -> JSON {
        mutex.lock(); defer { mutex.unlock() }
        let file = try sidecar(entry)
        if !FileManager.default.fileExists(atPath: file.path) { return .null }
        return try JSON(data: Data(contentsOf: file))
    }
    public func save(entry: String, _ value: JSON) throws {
        mutex.lock(); defer { mutex.unlock() }
        let file = try sidecar(entry)
        try value.encoded().write(to: file, options: .atomic)
        _ = chmod(file.path, S_IRUSR | S_IWUSR)
    }
    private func sidecar(_ entry: String) throws -> URL {
        guard descriptor >= 0 else { throw CrocheError("storage_error", "Storage is not owned") }
        guard !entry.isEmpty, entry.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else { throw CrocheError("storage_error", "Invalid storage entry") }
        return URL(fileURLWithPath: url.path + "." + entry)
    }
    // MARK: The turn archive (F20.6)
    public func appendLine(entry: String, _ line: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        let file = try segment(entry)
        guard !line.contains("\n") else { throw CrocheError("storage_error", "An archive line holds no newline") }
        let fd = open(file.path, O_RDWR | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CrocheError("storage_error", "Could not open the archive") }
        defer { _ = close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CrocheError("storage_error", "Could not read the archive") }
        var bytes = [UInt8]()
        if info.st_size > 0 {
            var last: UInt8 = 0
            guard pread(fd, &last, 1, off_t(info.st_size - 1)) == 1 else { throw CrocheError("storage_error", "Could not read the archive") }
            if last != 0x0a { bytes.append(0x0a) }   // a torn line never swallows this record
        }
        bytes += Array(line.utf8); bytes.append(0x0a)
        try Self.writeAll(fd, bytes)
        guard fsync(fd) == 0 else { throw CrocheError("storage_error", "Could not sync the archive") }
    }
    public func readLines(entry: String) throws -> [String] {
        mutex.lock(); defer { mutex.unlock() }
        let file = try segment(entry)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var lines = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeLast()   // the piece after the last newline: a torn line, or "" when whole
        return lines.filter { !$0.isEmpty }
    }
    public func replaceLines(entry: String, _ lines: [String]) throws {
        mutex.lock(); defer { mutex.unlock() }
        let file = try segment(entry)
        guard !lines.isEmpty else { return try unlinkIfPresent(file) }
        guard !lines.contains(where: { $0.contains("\n") }) else { throw CrocheError("storage_error", "An archive line holds no newline") }
        // '.' and '-' are outside the entry rule: a temporary is never an entry, `held` or `lock`.
        let nonce = UUID().uuidString.lowercased()
        let temporary = URL(fileURLWithPath: file.path + ".tmp-" + nonce)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CrocheError("storage_error", "Could not write the archive") }
        do {
            defer { _ = close(fd) }
            try Self.writeAll(fd, Array(lines.map { $0 + "\n" }.joined().utf8))
            guard fsync(fd) == 0 else { throw CrocheError("storage_error", "Could not sync the archive") }
        } catch { _ = unlink(temporary.path); throw error }
        do {
            try beforeCommit?(temporary)
            guard rename(temporary.path, file.path) == 0 else { throw CrocheError("storage_error", "Could not replace the archive") }
        } catch { _ = unlink(temporary.path); throw error }
    }
    public func remove(entry: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        try unlinkIfPresent(try sidecar(entry))
    }
    public func entries(prefix: String) throws -> [String: Int] {
        mutex.lock(); defer { mutex.unlock() }
        guard descriptor >= 0 else { throw CrocheError("storage_error", "Storage is not owned") }
        var found: [String: Int] = [:]
        for (name, path) in try siblings() {
            guard Self.isEntry(name), name.hasPrefix(prefix) else { continue }
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber { found[name] = size.intValue }
        }
        return found
    }
    /// Line entries are segments only: the archive's (`archive` and four digits) and the message
    /// log's (`log` and six digits, S1). Never the snapshot's own sidecars (`held`) or its lock
    /// file (`lock`).
    private func segment(_ entry: String) throws -> URL {
        guard Self.isSegment(entry) else { throw CrocheError("storage_error", "Invalid archive entry") }
        return try sidecar(entry)
    }
    private static func isSegment(_ entry: Substring) -> Bool {
        let digits = { (n: Int) in entry.dropFirst(n).allSatisfy { $0.isASCII && $0.isNumber } }
        return (entry.count == 11 && entry.hasPrefix("archive") && digits(7))
            || (entry.count == 9 && entry.hasPrefix("log") && digits(3))
    }
    private static func isSegment(_ entry: String) -> Bool { isSegment(Substring(entry)) }
    private static func isEntry(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }
    /// The files beside the snapshot: `<file>.<suffix>`, as (suffix, path).
    private func siblings() throws -> [(String, String)] {
        let directory = url.deletingLastPathComponent().path, base = url.lastPathComponent + "."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { $0.hasPrefix(base) }.map { (String($0.dropFirst(base.count)), directory + "/" + $0) }
    }
    /// Segment rewrites a crash interrupted (`archive<NNNN>.tmp-<nonce>`, `log<NNNNNN>.tmp-<nonce>`):
    /// deleted by the owner.
    private func removeStaleTemporaries() {
        for (suffix, path) in (try? siblings()) ?? [] {
            let parts = suffix.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, Self.isSegment(parts[0]), parts[1].hasPrefix("tmp-") else { continue }
            _ = unlink(path)
        }
    }
    private func unlinkIfPresent(_ file: URL) throws {
        if unlink(file.path) != 0 && errno != ENOENT { throw CrocheError("storage_error", "Could not delete the archive") }
    }
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { throw CrocheError("storage_error", "Could not write the archive") }
            offset += written
        }
    }

    public func remove() throws {
        try mutex.withLock {
            guard descriptor >= 0 else { throw CrocheError("storage_error", "Storage is not owned") }
            try unlinkIfPresent(url)
        }
    }

    public func release() {
        mutex.lock(); defer { mutex.unlock() }
        if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); _ = close(descriptor); descriptor = -1 }
    }
    deinit { release() }
}

// Project namespace, independent of every app-supplied RuntimeStorage. Core mints and
// validates the record; this host only owns its file, atomic replacement and flock.
final class ProjectRecordFiles: @unchecked Sendable {
    private let directory: @Sendable () -> URL?
    private let mutex = NSLock()
    private var descriptors: [String: Int32] = [:]
    // Internal host-test fences; configured before the host is handed to Core.
    var afterRead: (@Sendable (String, String?) -> Void)?
    var beforeLock: (@Sendable (String) -> Void)?
    var afterWrite: (@Sendable (String) -> Void)?
    init(directory: @escaping @Sendable () -> URL? = ProjectRecordFiles.defaultDirectory) { self.directory = directory }
    static var hasPrivateStorage: Bool {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
        true
        #else
        false
        #endif
    }
    // Policy seam lets host tests exercise a platform without a default on Apple too.
    static func forOpen(projectDirectory: URL?, hasPrivateStorage: Bool = ProjectRecordFiles.hasPrivateStorage) throws -> ProjectRecordFiles {
        if hasPrivateStorage {
            guard projectDirectory == nil else {
                throw CrocheError("invalid_configuration", "this platform keeps the project record in the app's private storage")
            }
            return ProjectRecordFiles()
        }
        guard let projectDirectory else {
            throw CrocheError("storage_error", "This platform requires projectDirectory for the project record")
        }
        return ProjectRecordFiles(directory: { projectDirectory })
    }
    static func defaultDirectory() -> URL? {
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #else
        return nil
        #endif
    }
    static func owns(_ key: String) -> Bool { key.hasPrefix("croche.project.") }
    func file(_ key: String) throws -> URL {
        let prefix = "croche.project.v1."
        let hash = key.dropFirst(prefix.count)
        guard key.hasPrefix(prefix), hash.count == 64, hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else {
            throw CrocheError("storage_error", "Unsupported project record key")
        }
        guard let directory = directory() else {
            throw CrocheError("storage_error", "Project record needs app-private storage or an explicit projectDirectory")
        }
        return directory.appendingPathComponent("croche.project.v1.\(hash).json")
    }
    private func io<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as CrocheError { throw error }
        catch { throw CrocheError("storage_error", "Could not access the project record directory") }
    }
    func acquire(_ key: String) throws {
        beforeLock?(key)
        try io { try mutex.withLock {
            guard descriptors[key] == nil else { throw CrocheError("store_busy", "Project record is already owned") }
            let url = try file(key)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CrocheError("storage_error", "Could not open project record lock") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                _ = close(fd); throw CrocheError("store_busy", "Project record is already owned")
            }
            descriptors[key] = fd
        } }
    }
    private func ownedFile(_ key: String) throws -> URL {
        guard descriptors[key] != nil else { throw CrocheError("storage_error", "Project record is not owned") }
        return try file(key)
    }
    func read(_ key: String) throws -> String? {
        let value = try io { try mutex.withLock {
            let url = try ownedFile(key)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil as String? }
            return try String(contentsOf: url, encoding: .utf8)
        } }
        afterRead?(key, value)
        return value
    }
    func write(_ key: String, _ value: String) throws {
        try io { try mutex.withLock {
            let url = try ownedFile(key)
            let temporary = URL(fileURLWithPath: url.path + ".tmp-" + UUID().uuidString)
            let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw CrocheError("storage_error", "Could not write project record") }
            defer { _ = close(fd); _ = unlink(temporary.path) }
            let bytes = Array(value.utf8)
            var offset = 0
            while offset < bytes.count {
                let count = bytes[offset...].withUnsafeBytes {
                    #if canImport(Glibc)
                    return Glibc.write(fd, $0.baseAddress, $0.count)
                    #else
                    return Darwin.write(fd, $0.baseAddress, $0.count)
                    #endif
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CrocheError("storage_error", "Could not write project record") }
                offset += count
            }
            guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
                throw CrocheError("storage_error", "Could not commit project record")
            }
        } }
        afterWrite?(key)
    }
    func release(_ key: String) {
        mutex.withLock {
            if let fd = descriptors.removeValue(forKey: key) { _ = flock(fd, LOCK_UN); _ = close(fd) }
        }
    }
    var held: Bool { mutex.withLock { !descriptors.isEmpty } }
    deinit {
        for fd in descriptors.values { _ = flock(fd, LOCK_UN); _ = close(fd) }
    }
}
