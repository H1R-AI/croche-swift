import Foundation
import CrocheFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The 0.6 storage primitives (ARCHITECTURE §2a): opaque UTF-8 values under Core-chosen keys.
/// Core owns names, framing and retention; this keeps bytes durable and nothing else.
/// Key encoding is reversible: two hex components, so a 200-byte key fits 255-byte names.
final class PlatformStorage: @unchecked Sendable {
    private let root: URL
    private let guarded = NSLock()
    /// Held lock files by lock name. flock is per open file: another handle (or process) on the
    /// same directory contends even inside this process.
    private var held: [String: Int32] = [:]

    init(directory: URL) { root = directory.appendingPathComponent("kv-v1", isDirectory: true) }

    /// Core's portable key grammar; anything else is a Core bug and never reaches the disk.
    static func valid(_ key: String) -> Bool {
        (1...200).contains(key.utf8.count) && key.utf8.allSatisfy { b in
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 46 || b == 95 || b == 47 || b == 45
        }
    }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    private func path(_ area: String, _ key: String, suffix: String) throws -> URL {
        guard Self.valid(key) else { throw LegacyCrocheError("storage_error", "Invalid storage key.") }
        let bytes = Array(key.utf8), split = min(100, bytes.count)
        return root.appendingPathComponent(area, isDirectory: true)
            .appendingPathComponent(Self.hex(bytes[..<split]), isDirectory: true)
            .appendingPathComponent(Self.hex(bytes[split...]) + suffix)
    }
    private static func decode(_ name: String) -> String? {
        guard name.utf8.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = [], digits = Array(name.utf8)
        var index = 0
        while index < digits.count {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte); index += 2
        }
        digits.removeAll()
        guard let key = String(bytes: bytes, encoding: .utf8), valid(key) else { return nil }
        return key
    }

    func read(_ area: String, _ key: String) throws -> String? {
        let file = try path(area, key, suffix: ".value")
        do { return String(decoding: try Data(contentsOf: file), as: UTF8.self) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw LegacyCrocheError("storage_error", "Storage read failed.") }
    }

    /// Atomic replace, durable on return: temp file, fsync, rename, then the directory's fsync.
    /// A crash leaves the old value or the new one, never a mix.
    func write(_ area: String, _ key: String, _ value: String) throws {
        let file = try path(area, key, suffix: ".value"), dir = file.deletingLastPathComponent()
        try ensure(dir)
        let temp = dir.appendingPathComponent(file.lastPathComponent + ".tmp-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw LegacyCrocheError("storage_error", "Storage write failed.") }
        let bytes = Array(value.utf8)
        var written = 0, ok = true
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { posixWrite(fd, $0.baseAddress! + written, bytes.count - written) }
            if n <= 0 { ok = false; break }
            written += n
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp.path, file.path) == 0 else {
            unlink(temp.path)
            throw LegacyCrocheError("storage_error", "Storage write failed.")
        }
        try sync(dir)
    }

    /// Real deletion; absent is not an error.
    func remove(_ area: String, _ key: String) throws {
        let file = try path(area, key, suffix: ".value")
        if unlink(file.path) != 0 && errno != ENOENT { throw LegacyCrocheError("storage_error", "Storage remove failed.") }
        if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) { try sync(file.deletingLastPathComponent()) }
    }

    /// All and only the keys starting with `prefix`, in any order. Temporary files are not keys.
    func list(_ area: String, _ prefix: String) throws -> [String] {
        let base = root.appendingPathComponent(area, isDirectory: true), files = FileManager.default
        guard let heads = try? files.contentsOfDirectory(atPath: base.path) else { return [] }
        var keys: [String] = []
        for head in heads {
            guard let tails = try? files.contentsOfDirectory(atPath: base.appendingPathComponent(head).path) else { continue }
            for tail in tails where tail.hasSuffix(".value") {
                guard let key = Self.decode(head + tail.dropLast(6)) else { throw LegacyCrocheError("storage_error", "Invalid storage filename.") }
                if key.hasPrefix(prefix) { keys.append(key) }
            }
        }
        return keys
    }

    /// Exclusive across handles and processes; contention is the fact `.held`, never an error
    /// and never a wait.
    @discardableResult func lock(_ name: String) throws -> PalLockOutcome {
        let file = try path("locks", name, suffix: ".lock")
        try ensure(file.deletingLastPathComponent())
        return try guarded.withLock {
            guard held[name] == nil else { return .held }
            let fd = open(file.path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else { throw LegacyCrocheError("storage_error", "Storage lock failed.") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let busy = errno == EWOULDBLOCK
                close(fd)
                if busy { return .held }
                throw LegacyCrocheError("storage_error", "Storage lock failed.")
            }
            held[name] = fd
            return .acquired
        }
    }
    func unlock(_ name: String) {
        guard let fd = guarded.withLock({ held.removeValue(forKey: name) }) else { return }
        flock(fd, LOCK_UN); close(fd)
    }

    private func ensure(_ dir: URL) throws {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw LegacyCrocheError("storage_error", "Storage directory failed.") }
    }
    private func sync(_ dir: URL) throws {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { throw LegacyCrocheError("storage_error", "Storage sync failed.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw LegacyCrocheError("storage_error", "Storage sync failed.") }
    }
}

#if canImport(Darwin)
private let posixWrite = Darwin.write
#else
private let posixWrite = Glibc.write
#endif

/// Where secrets live: apart from state, never through `read` or `list`.
protocol PlatformSecrets: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ key: String, _ value: String) throws
    func remove(_ key: String) throws
}

/// Files in their own area: hosts without a Keychain, and Croche's own tests.
struct FileSecrets: PlatformSecrets {
    let storage: PlatformStorage
    func read(_ key: String) throws -> String? { try storage.read("secrets", key) }
    func write(_ key: String, _ value: String) throws { try storage.write("secrets", key, value) }
    func remove(_ key: String) throws { try storage.remove("secrets", key) }
}

#if canImport(Security) && !os(Linux)
import Security

/// One Keychain generic-password item per Core secret key, readable after first unlock on
/// this device only (never in a backup or on another device).
struct KeychainSecrets: PlatformSecrets {
    var service = "ai.croche.pal"
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    func read(_ key: String) throws -> String? {
        var lookup = query(key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw LegacyCrocheError("storage_error", "Keychain read failed (\(status)).") }
        return String(decoding: data, as: UTF8.self)
    }
    func write(_ key: String, _ value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw LegacyCrocheError("storage_error", "Keychain write failed (\(update)).") }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw LegacyCrocheError("storage_error", "Keychain write failed (\(status)).") }
    }
    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LegacyCrocheError("storage_error", "Keychain delete failed (\(status)).") }
    }
}
#endif
