import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// Platform Abstraction Layer. The Rust Core decides; these perform what only the platform
// can: keep a credential in hardware-backed storage, and vouch for the app binary.
// See docs/MOBILE-SDK-AND-PAL.md.

/// Where the Runtime credential lives, apart from the general state file. load returns an
/// object (empty when nothing is stored). save replaces the whole object atomically.
public protocol RuntimeSecretStore: Sendable {
    func load() throws -> JSON
    func save(_ secrets: JSON) throws
    /// Removes the credential item for real; absence succeeds. No default implementation.
    func remove() throws
}

/// The platform's attestation of this app binary, bound to `clientDataHash`.
public struct RuntimeAttestation: Sendable {
    public let token: String
    public let keyId: String?
    public init(token: String, keyId: String?) { self.token = token; self.keyId = keyId }
}

public protocol RuntimeAttestor: Sendable {
    /// "ios-app-attest" or "android-play-integrity"; declared to the Core in config.
    var platform: String { get }
    /// `clientDataHash` is SHA-256(`clientData`), exactly as Cloud recomputes it.
    func attest(clientData: String, clientDataHash: Data) async throws -> RuntimeAttestation
}

/// The OS's deferred work for the agent's scheduled notes while the app is not running (founder
/// 17:14Z): `AppRefreshScheduler` (BGTaskScheduler) on iOS. The Runtime calls it with the earliest
/// pending note after every change, at every open, and after every `deliverDue()`. The work it
/// registers runs `deliverDue()`: inexact, never before that time. No exact alarms,
/// notifications or permissions.
public protocol RuntimeScheduler: Sendable {
    /// Replaces any earlier request with one at or after `earliest`. Idempotent: one request at a
    /// time, by identifier. Throw `CrocheError("not_configured", ...)` when the app is not set up
    /// for it: the Runtime reports `schedule.degraded` with that code and still delivers while
    /// running and at the next foreground or open.
    func schedule(earliest: Date) throws
    /// Nothing is pending: withdraw the request.
    func cancel()
    /// A Runtime is opening with this scheduler. Throw `CrocheError("scheduler_conflict", ...)`
    /// to refuse it when its identifier is already another open Runtime's: that identifier's
    /// runs could deliver through only one of them, including when the same scheduler object is
    /// given to a second Runtime.
    func attach() throws
    /// That Runtime closed (or failed to open): the identifier is free again. The Runtime calls
    /// this at most once per successful `attach`, however often it is closed.
    func detach()
}
public extension RuntimeScheduler {
    func attach() throws {}
    func detach() {}
}

/// One open Runtime per OS identity (an iOS task identifier): the rule the OS schedulers share,
/// kept in one place so the tests' schedulers run the same code as `AppRefreshScheduler` (Atlas,
/// #323 P1-2 and the NO at dc38bf0). `claim` is refused while the identity is held by anyone, the
/// claiming object included: `create` claims once per Runtime, so one object given to two
/// Runtimes is refused the second time. `release` frees it only for its holder.
final class SchedulerClaims: @unchecked Sendable {
    private let lock = NSLock()
    private var holders: [String: AnyObject] = [:]
    private let what: String
    init(what: String) { self.what = what }
    func claim(_ identity: String, by: AnyObject) throws {
        try lock.withLock {
            if holders[identity] != nil {
                throw CrocheError("scheduler_conflict", "Another open Runtime uses the \(what) \(identity); give each Runtime its own, or close it first")
            }
            holders[identity] = by
        }
    }
    func release(_ identity: String, by: AnyObject) { lock.withLock { if holders[identity] === by { holders[identity] = nil } } }
    func held(_ identity: String) -> Bool { lock.withLock { holders[identity] != nil } }
}

/// One background run the OS granted (a BGTaskScheduler launch): opens or reaches the app's
/// Runtime, delivers what is due, and reports whether that finished. `expire()` (the OS ending
/// background time) cancels this run's own delivery, waiting behind another turn or running,
/// never another turn of the Runtime (Atlas, #323 P1-1); after the run ended it does nothing.
/// The delivery's notes stay pending, registered again, for the next run or foreground.
final class BackgroundDelivery: @unchecked Sendable {
    private let open: @Sendable () async throws -> CrocheRuntime
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var expired = false
    init(open: @escaping @Sendable () async throws -> CrocheRuntime) { self.open = open }
    func start(_ done: @escaping @Sendable (Bool) -> Void) {
        let open = self.open
        let task = Task {
            let runtime: CrocheRuntime
            do { runtime = try await open() } catch { done(false); return }
            // Cancelling this Task cancels this delivery only (`deliverDue`). Expired before it
            // began, it is cancelled at once, and its notes are registered again.
            let result = try? await runtime.deliverDue()
            done(!Task.isCancelled && (result.map { $0["ran"].bool != true || $0["delivered"].bool == true } ?? false))
        }
        if lock.withLock({ self.task = task; return expired }) { task.cancel() }
    }
    func expire() { lock.withLock { expired = true; return task }?.cancel() }
}

/// A 0600 file beside the state file. For hosts without a secret store (Linux, tests,
/// command-line tools). On iOS and macOS apps, use KeychainSecretStore.
public final class FileRuntimeSecretStore: RuntimeSecretStore, @unchecked Sendable {
    private let url: URL
    private let mutex = NSLock()
    public init(url: URL) { self.url = url }
    public func load() throws -> JSON {
        mutex.lock(); defer { mutex.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return .object([:]) }
        let saved: JSON
        do { saved = try JSON(data: Data(contentsOf: url)) }
        catch { throw CrocheError("corrupt_store", "Runtime credentials are unreadable; remove them to register again") }
        guard saved.object != nil else { throw CrocheError("corrupt_store", "Runtime credentials must be an object") }
        return saved
    }
    public func save(_ secrets: JSON) throws {
        mutex.lock(); defer { mutex.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try secrets.encoded().write(to: url, options: .atomic)
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
    }
    public func remove() throws {
        try mutex.withLock {
            if unlink(url.path) != 0 && errno != ENOENT { throw CrocheError("storage_error", "Could not remove Runtime credentials") }
        }
    }

}

#if canImport(Security) && !os(Linux)
import Security

/// Keychain generic password, `AfterFirstUnlockThisDeviceOnly`: readable by background work
/// after the first unlock, never synced or restored to another device. It survives app
/// reinstall on iOS, so a reinstall keeps the same Runtime (and its credit) rather than
/// minting a new one.
public final class KeychainSecretStore: RuntimeSecretStore, @unchecked Sendable {
    private let service: String
    private let account: String
    /// `account` should be the Runtime's storage key, so each agent's store has its own item.
    public init(service: String = "ai.croche.runtime", account: String) {
        self.service = service; self.account = account
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    public func load() throws -> JSON {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return .object([:]) }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CrocheError("storage_error", "Keychain read failed (\(status))")
        }
        guard let saved = try? JSON(data: data), saved.object != nil else {
            throw CrocheError("corrupt_store", "Runtime credentials are unreadable; remove them to register again")
        }
        return saved
    }
    public func save(_ secrets: JSON) throws {
        let data = try secrets.encoded()
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CrocheError("storage_error", "Keychain write failed (\(update))") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CrocheError("storage_error", "Keychain write failed (\(status))") }
    }
    public func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CrocheError("storage_error", "Keychain delete failed (\(status))")
        }
    }

}
#endif

#if canImport(DeviceCheck)
import DeviceCheck

/// Apple App Attest. Each registration generates a fresh key and attests it against the
/// Cloud challenge; Cloud checks the chain to Apple's root, the app id, and the nonce.
/// Simulators cannot attest: use a development project with attestation off there.
public struct AppAttestAttestor: RuntimeAttestor {
    public let platform = "ios-app-attest"
    public init() {}
    public func attest(clientData: String, clientDataHash: Data) async throws -> RuntimeAttestation {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw CrocheError("attestation_unsupported", "App Attest is not available here (simulators cannot attest)")
        }
        let keyId = try await service.generateKey()
        let object = try await service.attestKey(keyId, clientDataHash: clientDataHash)
        return RuntimeAttestation(token: object.base64EncodedString(), keyId: keyId)
    }
}
#endif

func base64URLDecode(_ text: String) -> Data? {
    var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while value.count % 4 != 0 { value += "=" }
    return Data(base64Encoded: value)
}

/// Incremental text/event-stream framing, over bytes: a read can split anywhere, including
/// inside a UTF-8 character or between CR and LF. Blocks are decoded only once complete.
/// The same rules as packages/runtime/src/sse.ts.
struct EventStreamParser {
    struct Event: Equatable { let event: String; let data: String }
    private var buffer = [UInt8]()
    private var carriageReturn = false

    mutating func push(_ bytes: [UInt8]) -> [Event] {
        for byte in bytes {
            if carriageReturn {
                carriageReturn = false
                buffer.append(0x0A)
                if byte == 0x0A { continue }
            }
            if byte == 0x0D { carriageReturn = true } else { buffer.append(byte) }
        }
        return drain()
    }
    /// End of stream: a held CR can no longer be half of a CRLF, so it ends its line.
    mutating func end() -> [Event] {
        guard carriageReturn else { return [] }
        carriageReturn = false; buffer.append(0x0A)
        return drain()
    }
    private mutating func drain() -> [Event] {
        var events: [Event] = []
        var start = 0
        var index = 0
        while index + 1 < buffer.count {
            if buffer[index] == 0x0A && buffer[index + 1] == 0x0A {
                if let event = Self.block(String(decoding: buffer[start..<index], as: UTF8.self)) { events.append(event) }
                index += 2; start = index
            } else { index += 1 }
        }
        if start > 0 { buffer.removeFirst(start) }
        return events
    }
    private static func block(_ text: String) -> Event? {
        var name = "message"
        var data: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty || line.hasPrefix(":") { continue }
            let field: Substring, value: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[..<colon]
                var rest = line[line.index(after: colon)...]
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                value = rest
            } else { field = line; value = "" }
            if field == "event" { name = String(value) } else if field == "data" { data.append(String(value)) }
        }
        return data.isEmpty ? nil : Event(event: name, data: data.joined(separator: "\n"))
    }
}
