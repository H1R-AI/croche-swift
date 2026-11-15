import Foundation
import CrocheFFI

/// ARCHITECTURE §2a: the ONE storage interface, the same methods on every SDK. Omitted in
/// `OpenOptions` = the platform default (Application Support files, Keychain secrets). A custom
/// store (servers: KV, Redis, S3) implements exactly this. Keys and layout are Core's.
public protocol StoragePal: Sendable {
    /// nil = absent.
    func read(_ key: String) async throws -> String?
    /// ATOMIC REPLACE, durable on return.
    func write(_ key: String, _ value: String) async throws
    /// A real delete; absent = ok.
    func remove(_ key: String) async throws
    /// Keys starting with `prefix`, any order.
    func list(_ prefix: String) async throws -> [String]
    /// Exclusive across processes; never waits. Another owner holding it is the FACT
    /// `.held`, not an error; Core maps it. A throw is a failure (Core's `storage_error`).
    func lock(_ name: String) async throws -> LockOutcome
    func unlock(_ name: String) async throws
    var secrets: any SecretsPal { get }
}

/// What `lock` found (ARCHITECTURE §2a).
public enum LockOutcome: Sendable, Equatable { case acquired, held }

public protocol SecretsPal: Sendable {
    func read(_ key: String) async throws -> String?
    func write(_ key: String, _ value: String) async throws
    func remove(_ key: String) async throws
}

/// A storage failure reports facts only (ARCHITECTURE §2/§2a, Leo 12:39Z): its text, for
/// debugging. No code or category crosses, whatever the app threw; Core reports `storage_error`.
func storageFailure(_ error: Error) -> CoreStorageFailure {
    if let error = error as? CoreStorageFailure { return error }
    if let error = error as? CrocheError { return .Failure(detail: error.message) }
    if case let .Failure(_, message)? = error as? FfiError { return .Failure(detail: message) }
    return .Failure(detail: "\(error)")
}

/// The app's `StoragePal` as Core's callback. Core calls it on a Core thread (never the
/// cooperative pool: see `blocking`), so waiting for the app's async method is safe there.
/// Whatever the app throws reaches Core as text only; contention is `lock`'s `.held`.
final class CoreStorageAdapter: CoreStoragePal, @unchecked Sendable {
    let storage: any StoragePal
    init(_ storage: any StoragePal) { self.storage = storage }

    private func wait<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Error>!
        appTask { result = await Result { try await body() }; done.signal() }
        done.wait()
        do { return try result.get() } catch { throw storageFailure(error) }
    }

    func read(key: String) throws -> String? { let s = storage; return try wait { try await s.read(key) } }
    func write(key: String, value: String) throws { let s = storage; try wait { try await s.write(key, value) } }
    func remove(key: String) throws { let s = storage; try wait { try await s.remove(key) } }
    func list(prefix: String) throws -> [String] { let s = storage; return try wait { try await s.list(prefix) } }
    func lock(name: String) throws -> PalLockOutcome {
        let s = storage
        switch try wait({ try await s.lock(name) }) { case .acquired: return .acquired; case .held: return .held }
    }
    func unlock(name: String) throws { let s = storage; try wait { try await s.unlock(name) } }
    func readSecret(key: String) throws -> String? { let s = storage.secrets; return try wait { try await s.read(key) } }
    func writeSecret(key: String, value: String) throws { let s = storage.secrets; try wait { try await s.write(key, value) } }
    func removeSecret(key: String) throws { let s = storage.secrets; try wait { try await s.remove(key) } }
}

private extension Result where Failure == Error {
    init(_ body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}

/// The platform default store as Core's storage argument (Keel 16:08Z): the argument always
/// carries a PAL, the app's or this one; Core has no storage default of its own. The options JSON
/// still omits `storage` here, so Core can tell the default from an app store.
final class PlatformStorageAdapter: CoreStoragePal, @unchecked Sendable {
    let pal: PlatformPal
    init(_ pal: PlatformPal) { self.pal = pal }

    private func call<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw storageFailure(error) }
    }

    func read(key: String) throws -> String? { try call { try pal.read(key: key) } }
    func write(key: String, value: String) throws { try call { try pal.write(key: key, value: value) } }
    func remove(key: String) throws { try call { try pal.remove(key: key) } }
    func list(prefix: String) throws -> [String] { try call { try pal.list(prefix: prefix) } }
    func lock(name: String) throws -> PalLockOutcome { try call { try pal.lock(key: name) } }
    func unlock(name: String) throws { pal.unlock(key: name) }
    func readSecret(key: String) throws -> String? { try call { try pal.readSecret(key: key) } }
    func writeSecret(key: String, value: String) throws { try call { try pal.writeSecret(key: key, value: value) } }
    func removeSecret(key: String) throws { try call { try pal.removeSecret(key: key) } }
}
