import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CrocheFFI

// The Swift PAL: what only the platform can do. The Rust Runtime (crates/croche-ffi) decides
// everything else, including SSE framing, response bounds, timeouts' meaning, persistence
// order, upkeep and cancellation rules. Its calls into this host block a background thread.

extension CrocheError {
    init(_ error: Error) {
        if let e = error as? CrocheError { self = e }
        else if case let .Failure(code, message)? = error as? FfiError { self.init(code, message) }
        else { self.init("host_error", "The host operation failed") }
    }
    var ffi: FfiError { .Failure(code: code, message: message) }
}

/// The binding's `identity`, named so `CrocheRuntime.identity` does not shadow it. Unqualified:
/// the React Native pod compiles the SDK and its bindings into one module.
func ffiIdentity(_ config: String) throws -> String { try identity(config: config) }

/// Runs `body` on the Swift concurrency pool and blocks this (Rust-owned, background) thread
/// until it finishes, `cancel` fires or `milliseconds` pass.
func blockOn<T: Sendable>(milliseconds: Double?, cancel: CancelToken?,
                          _ body: @escaping @Sendable (RuntimeCancellation) async throws -> T) throws -> T {
    let cancellation = RuntimeCancellation()
    cancel?.onCancel(callback: CancelHook(cancellation))
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.set(.success(try await bounded(milliseconds: milliseconds, cancellation: cancellation, body: body))) }
        catch { box.set(.failure(error)) }
        done.signal()
    }
    done.wait()
    do { return try box.get() } catch { throw CrocheError(error).ffi }
}

/// An app command (H1): runs `body` until it returns, however long after a cancel. The cancel
/// (the turn's, or the command's deadline: the Runtime is its only clock) reaches the handler
/// through its `RuntimeCancellation`, as before H1. The Task itself is not cancelled: a handler
/// polling with `try? await Task.sleep` would then spin on the cooperative pool. The Runtime has
/// already stopped waiting, so only this abandoned worker waits, and the command's slot stays
/// held until the handler is done.
func blockUntilSettled<T: Sendable>(cancel: CancelToken,
                                    _ body: @escaping @Sendable (RuntimeCancellation) async throws -> T) throws -> T {
    let cancellation = RuntimeCancellation()
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let run: @Sendable () async -> Void = {
        do { try cancellation.check(); box.set(.success(try await body(cancellation))) }
        catch { box.set(.failure(error)) }
        done.signal()
    }
    // Handlers run on `ToolThreads` where the OS has task executors, apart from the cooperative
    // pool, and on that pool before. Neither path makes blocking safe: async handlers must not
    // block, and blocking work goes through `blockingTool`, a thread of its own on every OS.
    // Keep this branch (Keel, #342). `ToolExecution.forceFallback` lets the tests run the
    // earlier-OS path, and `AtlasH1ReviewTests` and `BlockingToolTests` cover both paths.
    if !ToolExecution.forceFallback, #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
        Task(executorPreference: ToolThreads.shared) { await run() }
    } else {
        Task { await run() }
    }
    cancel.onCancel(callback: CancelHook(cancellation))
    done.wait()
    if cancellation.isCancelled { throw CrocheError("cancelled", "The operation was cancelled").ffi }
    do { return try box.get() } catch { throw handlerError(error).ffi }
}

/// For tests: run handlers as an OS without `TaskExecutor` does (on Swift's cooperative pool).
enum ToolExecution { nonisolated(unsafe) static var forceFallback = false }

/// Thrown by an SDK bridge's own handler (React Native, compiled into this module) when it has
/// no handler of its own to run, before anything ran. Internal: app code cannot claim it.
struct ToolNotDispatched: Error {}

/// An error from a tool handler. "Nothing ran" is the host's to say, never a handler's: a
/// handler that throws `tool_not_dispatched` or `host_unresponsive` (perhaps passing on another
/// Runtime's error) may already have had its effect, so the call fails as `tool_failed`.
func handlerError(_ error: Error) -> CrocheError {
    if error is ToolNotDispatched { return CrocheError("tool_not_dispatched", "No handler ran for this tool") }
    let e = CrocheError(error)
    return ["tool_not_dispatched", "host_unresponsive"].contains(e.code) ? CrocheError("tool_failed", e.message) : e
}

/// Where app command handlers run (H1), where the OS has task executors: GCD threads, apart from
/// Swift's cooperative pool, which also runs the Runtime's own requests. This does not make a
/// blocking async handler safe (measured on Linux, #342); blocking work uses `blockingTool`.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class ToolThreads: TaskExecutor, @unchecked Sendable {
    static let shared = ToolThreads()
    private let queue = DispatchQueue(label: "dev.croche.tools", attributes: .concurrent)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job), executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

final class CancelHook: CancelCallback, @unchecked Sendable {
    private let cancellation: RuntimeCancellation
    init(_ cancellation: RuntimeCancellation) { self.cancellation = cancellation }
    func cancelled() { cancellation.cancel() }
}
final class EventHook: EventListener, @unchecked Sendable {
    private let callback: @Sendable (JSON) -> Void
    init(_ callback: @escaping @Sendable (JSON) -> Void) { self.callback = callback }
    func onEvent(event: String) { if let value = try? JSON(event) { callback(value) } }
}
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func set(_ result: Result<T, Error>) { lock.withLock { value = result } }
    func get() throws -> T { try lock.withLock { value! }.get() }
}

/// An ISO time as epoch ms.
private func epochMs(_ text: String) -> Double? {
    let parse = ISO8601DateFormatter()
    parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parse.date(from: text) { return date.timeIntervalSince1970 * 1000 }
    parse.formatOptions = [.withInternetDateTime]
    return parse.date(from: text).map { $0.timeIntervalSince1970 * 1000 }
}
/// The `at`s (epoch ms) of a schedule set `[{id, at}]`.
func times(_ entries: JSON) -> [Double] { (entries.array ?? []).compactMap { $0["at"].string.flatMap(epochMs) } }
/// A delivery's `retryAt` (epoch ms, or an ISO time), or nil.
func retryAt(_ value: JSON) -> Double? { value.number ?? value.string.flatMap(epochMs) }

/// The Swift PAL handed to the Rust Runtime.
final class SwiftHost: HostPal, @unchecked Sendable {
    private let storage: any RuntimeStorage
    private let projectRecords: ProjectRecordFiles
    // Internal test trace, configured before Core starts; records only delegated store calls.
    var beforeStoreAccess: (@Sendable (String) -> Void)?
    private let secretStore: any RuntimeSecretStore
    private let attestor: (any RuntimeAttestor)?
    private let http: RuntimeHTTP?
    /// The default transport's session, closed with the Runtime.
    let session = RuntimeSession()
    // Accepted tools are never removed: a tool change waits its turn in the Core's queue, and turns queued before it
    // still run the old list. The Core alone decides which commands a turn may call.
    private var handlers: [String: ToolHandler]
    private var staged: [String: Int] = [:], stamp = 0   // names whose only handler is from a call in flight
    private let identity: String
    private let background: Bool
    private let lock = NSLock()
    private weak var core: CoreRuntime?
    private var wakeTarget: Double?
    private var timer: Task<Void, Never>?
    private var stopped = false
    /// This Runtime's attachment to `osScheduler` (attached right after the host is built),
    /// released once: a second stop, or a stale close after the scheduler was attached again for
    /// another Runtime, must not free an identifier someone else holds. Guarded by `lock`.
    private var osAttached = false
    private let osScheduler: (any RuntimeScheduler)?
    var timeZone: TimeZone?
    private var wallClock: @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }
    /// The wall clock (epoch ms) the Runtime and its timers read. Tests move it.
    var clock: @Sendable () -> Double {
        get { lock.withLock { wallClock } }
        set { lock.withLock { wallClock = newValue } }
    }
    private var deliverDue: (@Sendable () async -> Void)?
    /// Runs `deliverDue()` on the Runtime when the earliest note's time comes.
    var deliver: (@Sendable () async -> Void)? {
        get { lock.withLock { deliverDue } }
        set { lock.withLock { deliverDue = newValue } }
    }
    private var dueAt: Double?
    private var fired: Double?
    private var dueTimer: Task<Void, Never>?

    init(storage: any RuntimeStorage, secrets: any RuntimeSecretStore, attestor: (any RuntimeAttestor)?,
         http: RuntimeHTTP?, tools: [String: ToolHandler], background: Bool,
         scheduler: (any RuntimeScheduler)? = nil, projectRecords: ProjectRecordFiles = ProjectRecordFiles()) {
        self.storage = storage; self.projectRecords = projectRecords; secretStore = secrets; self.attestor = attestor; self.http = http
        handlers = tools; self.background = background; osScheduler = scheduler
        identity = "\(ObjectIdentifier(storage as AnyObject).hashValue)"
    }

    private func host<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw CrocheError(error).ffi }
    }

    // MARK: HTTP
    func http(request: PalHttpRequest, sink: HttpSink, cancel: CancelToken) throws {
        let transport = http, session = session
        _ = try blockOn(milliseconds: Double(request.timeoutMs), cancel: cancel) { signal -> Bool in
            if let transport { try await Self.adapt(transport, request, sink, signal) }
            else { try await session.stream(request, into: sink, cancellation: signal) }
            return true
        }
    }

    /// An app transport speaks whole effects (`RuntimeHTTP`): its answer goes to the Runtime as
    /// a response, and its stream deltas as server-sent events.
    private static func adapt(_ transport: RuntimeHTTP, _ request: PalHttpRequest, _ sink: HttpSink,
                              _ signal: RuntimeCancellation) async throws {
        var headers: [String: JSON] = [:]
        for header in request.headers { headers[header.name] = .string(header.value) }
        let effect = JSON.object(["url": .string(request.url), "method": .string(request.method), "headers": .object(headers),
                                  "body": (try? JSON(request.body)) ?? .string(request.body),
                                  "timeoutMs": .number(Double(request.timeoutMs))])
        let streaming = StreamStart()
        let reply = try await transport(effect, signal) { data in
            if streaming.begin() {
                sink.head(status: 200, headers: [PalHeader(name: "content-type", value: "text/event-stream")])
            }
            let frame = data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)\n" }.joined() + "\n"
            _ = sink.chunk(bytes: Data(frame.utf8))
        }
        let status = UInt16(reply["status"].number ?? 0)
        var fields = (reply["headers"].object ?? [:]).compactMap { key, value in value.string.map { PalHeader(name: key, value: $0) } }
        if reply["streamed"] == .bool(true) {
            if streaming.begin() { sink.head(status: status, headers: [PalHeader(name: "content-type", value: "text/event-stream")]) }
            return
        }
        fields.removeAll { $0.name.lowercased() == "content-type" }
        fields.append(PalHeader(name: "content-type", value: "application/json"))
        sink.head(status: status, headers: fields)
        let body = reply["body"] != .null ? try reply["body"].encoded() : Data((reply["raw"].string ?? "").utf8)
        if !body.isEmpty { _ = sink.chunk(bytes: body) }
    }

    // MARK: Storage
    /// The Core names its snapshot by the key it locks, and other records `<key>.<entry>` (F19's
    /// held sends: `<key>.held`). Each goes to its own place: an entry never replaces the snapshot.
    private var snapshotKey: String? { get { lock.withLock { lockedKey } } set { lock.withLock { lockedKey = newValue } } }
    private var lockedKey: String?
    private func entry(_ key: String) throws -> String? {
        guard let main = snapshotKey, key != main else { return nil }
        guard key.hasPrefix(main + "."), key.count > main.count + 1 else { throw CrocheError("storage_error", "Unknown storage key") }
        return String(key.dropFirst(main.count + 1))
    }
    func read(key: String) throws -> String? {
        try host {
            if ProjectRecordFiles.owns(key) { return try projectRecords.read(key) }
            beforeStoreAccess?(key)
            let state: JSON
            if let name = try entry(key) {
                // A storage without entries never stored one.
                guard let keyed = storage as? any KeyedRuntimeStorage else { return nil }
                state = try keyed.load(entry: name)
            } else { state = try storage.load() }
            return state == .null ? nil : String(decoding: try state.encoded(), as: UTF8.self)
        }
    }
    func write(key: String, value: String) throws {
        try host {
            if ProjectRecordFiles.owns(key) { return try projectRecords.write(key, value) }
            beforeStoreAccess?(key)
            guard let name = try entry(key) else { return try storage.save(try JSON(value)) }
            guard let keyed = storage as? any KeyedRuntimeStorage else {
                throw CrocheError("storage_error", "This RuntimeStorage keeps only its snapshot")
            }
            try keyed.save(entry: name, try JSON(value))
        }
    }
    func readSecret(key: String) throws -> String? {
        try host { String(decoding: try secretStore.load().encoded(), as: UTF8.self) }
    }
    func writeSecret(key: String, value: String) throws { try host { try secretStore.save(try JSON(value)) } }
    func remove(key: String) throws {
        try host {
            guard !ProjectRecordFiles.owns(key) else { throw CrocheError("storage_error", "The project record is kept when agent data is removed") }
            beforeStoreAccess?(key)
            if let name = try entry(key) {
                guard let keyed = storage as? any KeyedRuntimeStorage else { return }
                try keyed.remove(entry: name)
            } else { try storage.remove() }
        }
    }
    func removeSecret(key: String) throws { try host { try secretStore.remove() } }
    func lock(key: String) throws {
        try host {
            if ProjectRecordFiles.owns(key) { return try projectRecords.acquire(key) }
            guard !projectRecords.held else { throw CrocheError("storage_error", "Release the project record lock before taking a store lock") }
            beforeStoreAccess?(key)
            try storage.acquire(); snapshotKey = key
        }
    }
    func unlock(key: String) {
        if ProjectRecordFiles.owns(key) { projectRecords.release(key); return }
        beforeStoreAccess?(key)
        stop(); storage.release(); snapshotKey = nil
    }
    func storeIdentity() -> String { identity }

    // MARK: The turn archive (F20.6)
    /// The storage's archive, or the typed "no archive": the Runtime then keeps none, and every
    /// turn, clearHistory and memory work as before.
    private func archive() throws -> any ArchiveRuntimeStorage {
        guard let archive = storage as? any ArchiveRuntimeStorage else {
            throw CrocheError("archive_unavailable", "This host keeps no turn archive.")
        }
        return archive
    }
    func archiveAppendLine(entry: String, line: String) throws { try host { try archive().appendLine(entry: entry, line) } }
    func archiveReadLines(entry: String) throws -> [String] { try host { try archive().readLines(entry: entry) } }
    func archiveReplaceLines(entry: String, lines: [String]) throws { try host { try archive().replaceLines(entry: entry, lines) } }
    func archiveRemove(entry: String) throws { try host { try archive().remove(entry: entry) } }
    func archiveEntries(prefix: String) throws -> [ArchiveEntry] {
        try host { try archive().entries(prefix: prefix).sorted { $0.key < $1.key }.map { ArchiveEntry(entry: $0.key, bytes: UInt64($0.value)) } }
    }
    /// Where the message log goes (S1, rev 4 §17.13): in lines when the storage appends them, in
    /// entries when it keeps entries, else inside the snapshot. Never refused.
    func storageCapability() -> StorageCapability {
        if storage is any ArchiveRuntimeStorage { return .lines }
        if storage is any KeyedRuntimeStorage { return .keyed }
        return .snapshot
    }

    /// Stages the handlers for names with none yet, or with one only staged by a call still in
    /// flight (a later call wins). Returns the stamp that `unstageTools` needs.
    func stageTools(_ tools: [String: ToolHandler]) -> Int {
        lock.withLock {
            stamp += 1
            for (name, handler) in tools where handlers[name] == nil || staged[name] != nil {
                handlers[name] = handler; staged[name] = stamp
            }
            return stamp
        }
    }
    /// A refused call: removes what it staged, unless a later call has staged the name since.
    func unstageTools(_ names: Dictionary<String, ToolHandler>.Keys, stamp: Int) {
        lock.withLock { for name in names where staged[name] == stamp { handlers[name] = nil; staged[name] = nil } }
    }
    /// An accepted call: its handlers serve every name it passed.
    func acceptTools(_ tools: [String: ToolHandler]) {
        lock.withLock { for (name, handler) in tools { handlers[name] = handler; staged[name] = nil } }
    }

    // MARK: Tools and attestation
    func tool(invocation: String, cancel: CancelToken) throws -> ToolOutput {
        let call = try host { try JSON(invocation) }
        guard let name = call["tool"].string, let handler = lock.withLock({ handlers[name] }) else {
            // Nothing ran, and the Runtime may tell the model so (driver.rs NOT_DISPATCHED).
            throw FfiError.Failure(code: "tool_not_dispatched", message: "The host tool is not available")
        }
        var invocation = JSON.object(["tool": call["tool"], "key": call["key"], "args": call["args"]])
        if call["command"] != .null { invocation["command"] = call["command"] }
        let context = call["context"], request = invocation, sink = ImageSink()
        // No deadline here: the Runtime times the call and cancels it (H4). This returns when
        // the handler does, so a stuck one keeps its slot (H1).
        let value = try blockUntilSettled(cancel: cancel) { signal in
            try await handler(request, ToolContext(data: context, cancellation: signal, images: sink))
        }
        // A plain handler's JSON is the value as it was; a `withResult` one's images ride beside
        // it, one sink per call (never shared between concurrent calls).
        return ToolOutput(value: String(decoding: try host { try value.encoded() }, as: UTF8.self),
                          images: try sink.take().map(Images.record))
    }
    func attest(request: String, timeoutMs: UInt64) throws -> String {
        guard let attestor else { throw FfiError.Failure(code: "attestation_unsupported", message: "This host has no attestor") }
        let effect = try host { try JSON(request) }
        guard let clientData = effect["clientData"].string, let hash = base64URLDecode(effect["clientDataHash"].string ?? "") else {
            throw FfiError.Failure(code: "invalid_abi", message: "Malformed attest effect")
        }
        let proof = try blockOn(milliseconds: Double(timeoutMs), cancel: nil) { _ -> JSON in
            let proof = try await attestor.attest(clientData: clientData, clientDataHash: hash)
            return .object(["platform": .string(attestor.platform), "token": .string(proof.token),
                            "keyId": proof.keyId.map { .string($0) } ?? .null])
        }
        return String(decoding: try host { try proof.encoded() }, as: UTF8.self)
    }

    // MARK: Clock, entropy, timer
    func nowMs() -> Double { clock() }
    func utcOffsetMinutes(atMs: Double) -> Int64 {
        Int64((timeZone ?? TimeZone.current).secondsFromGMT(for: Date(timeIntervalSince1970: atMs / 1000)) / 60)
    }
    func random() -> String { UUID().uuidString }
    func wake(atMs: Double?) {
        lock.withLock { wakeTarget = atMs }
        arm()
    }
    /// The agent's whole pending schedule set (JSON `[{id, at}]`), after each durable change and at
    /// open: a timer while running, and the OS's deferred work (`scheduler`) for after. A refused
    /// registration fails this acknowledgement, which the Core reports as `schedule.degraded`
    /// with its code.
    func schedule(entries: String) throws { try host { try applySchedule(target(times(try JSON(entries)))) } }
    private var retryFloor: Double?
    /// A failed delivery answered `retryAt`: a note already due waits until then.
    func retryAfter(_ at: Double) { lock.withLock { retryFloor = at } }
    /// When to wake for these notes: the earliest `at`, except that a note already due waits for
    /// a later `retryAt` (a delivery failed).
    func target(_ times: [Double]) -> Double? {
        let now = clock()
        let floor = lock.withLock { retryFloor }.flatMap { $0 > now ? $0 : nil }
        return times.map { at in floor.map { at <= now ? $0 : at } ?? at }.min()
    }
    /// Arms the timer for `at` (nil: nothing pending) and registers it with the OS.
    func applySchedule(_ at: Double?) throws {
        lock.withLock { dueAt = at }
        armDelivery()
        guard let os = osScheduler else { return }
        do {
            if let at { try os.schedule(earliest: Date(timeIntervalSince1970: at / 1000)) } else { os.cancel() }
        } catch let error as CrocheError { throw error }
        catch { throw CrocheError("schedule_failed", "The OS scheduler refused the request") }
    }
    /// A delivery is starting: it covers every note due now, so the timer never retries one.
    func attempted() { let now = clock(); lock.withLock { fired = max(fired ?? -.infinity, now) } }
    /// The Runtime is open: a wake it asked for while opening can now fire.
    func attach(_ core: CoreRuntime) { lock.withLock { self.core = core }; arm(); armDelivery() }
    /// The Runtime is opening: attach it to the OS scheduler (which may refuse with
    /// `scheduler_conflict`); `stop` releases that attachment once.
    func attachScheduler() throws {
        guard let os = osScheduler else { return }
        try os.attach()
        lock.withLock { osAttached = true }
    }
    func stop() {
        let release = lock.withLock {
            stopped = true; timer?.cancel(); timer = nil; dueTimer?.cancel(); dueTimer = nil
            defer { osAttached = false }
            return osAttached
        }
        if release { osScheduler?.detach() }
    }
    /// One timer at the earliest note, never firing a delivery before its time (a timer that ends
    /// early re-arms), and at most once per time: a delivery that was cut short leaves its notes
    /// for the next open, foreground or OS run rather than retrying at once.
    private func armDelivery() {
        let now = clock()
        lock.withLock {
            dueTimer?.cancel(); dueTimer = nil
            guard !stopped, core != nil, let target = dueAt, !(fired.map { target <= $0 } ?? false) else { return }
            let delay = max(0, target - now)
            dueTimer = Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.due(target)
            }
        }
    }
    private func due(_ target: Double) async {
        if clock() < target { armDelivery(); return }
        let run: (@Sendable () async -> Void)? = lock.withLock {
            if stopped { return nil }
            fired = target
            return deliverDue
        }
        await run?()
    }
    private func arm() {
        lock.withLock {
            timer?.cancel(); timer = nil
            guard background, !stopped, let target = wakeTarget, let core else { return }
            timer = Task.detached { [weak core] in
                let delay = max(0, target - Date().timeIntervalSince1970 * 1000)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
                guard !Task.isCancelled, let core else { return }
                Thread.detachNewThread { core.tick() }
            }
        }
    }
}

private final class StreamStart: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    /// True once: the first caller starts the stream.
    func begin() -> Bool { lock.withLock { if started { return false }; started = true; return true } }
}

/// The default transport's connections: one ephemeral URLSession per Runtime, so consecutive
/// calls (a first launch's challenge, register and sync; a turn's gateway calls) reuse a
/// connection instead of paying DNS, TCP and TLS again. As before: no cookies, cache, stored
/// credentials or redirects, and each request keeps its own timeout. Closing the Runtime
/// invalidates it; a request after that is refused.
final class RuntimeSession: @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private let router = HTTPStreamDelegate()
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: router, delegateQueue: nil)
    }
    deinit { session?.invalidateAndCancel() }
    var isClosed: Bool { lock.withLock { session == nil } }
    /// Cancels what is in flight and refuses every later request.
    func close() {
        let closing = lock.withLock { () -> URLSession? in defer { session = nil }; return session }
        closing?.invalidateAndCancel()
    }
    /// A task on this session whose parts arrive on the returned stream. Never on a closed one.
    private func start(_ request: URLRequest) throws -> (URLSessionDataTask, AsyncThrowingStream<HTTPPart, Error>) {
        let (parts, continuation) = AsyncThrowingStream<HTTPPart, Error>.makeStream()
        return try lock.withLock {
            guard let session else { throw CrocheError("network_error", "The Runtime is closed") }
            let task = session.dataTask(with: request)
            router.register(task, continuation)
            return (task, parts)
        }
    }
    /// The response goes to the Runtime as it arrives. The Runtime frames and bounds it.
    func stream(_ request: PalHttpRequest, into sink: any HttpSinkProtocol, cancellation: RuntimeCancellation) async throws {
        try cancellation.check()
        guard let url = URL(string: request.url) else { throw CrocheError("network_error", "Invalid HTTP effect URL") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        if !["GET", "HEAD"].contains(request.method) { urlRequest.httpBody = Data(request.body.utf8) }
        urlRequest.timeoutInterval = Double(request.timeoutMs) / 1000
        urlRequest.httpShouldHandleCookies = false
        for header in request.headers { urlRequest.setValue(header.value, forHTTPHeaderField: header.name) }
        let (task, parts) = try start(urlRequest)
        let listener = cancellation.observe { task.cancel() }
        // Only this request ends here: a finished task ignores the cancel, an unfinished one
        // (cancelled, or refused by the sink) gives up its connection, never another's.
        defer { cancellation.remove(listener); task.cancel() }
        task.resume()
        for try await part in parts {
            switch part {
            case .head(let status, let fields, _):
                sink.head(status: UInt16(clamping: status),
                          headers: fields.compactMap { key, value in value.string.map { PalHeader(name: key, value: $0) } })
            case .body(let data):
                // The Runtime wants no more (a bound was exceeded): stop reading.
                if !sink.chunk(bytes: data) { return }
            }
        }
        try cancellation.check()
    }
}

/// The session's delegate: hands each task's callbacks to that task's stream.
private final class HTTPStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: AsyncThrowingStream<HTTPPart, Error>.Continuation] = [:]
    func register(_ task: URLSessionTask, _ sink: AsyncThrowingStream<HTTPPart, Error>.Continuation) {
        lock.withLock { sinks[task.taskIdentifier] = sink }
    }
    private func sink(_ task: URLSessionTask) -> AsyncThrowingStream<HTTPPart, Error>.Continuation? {
        lock.withLock { sinks[task.taskIdentifier] }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let sink = sink(dataTask) else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse else {
            sink.finish(throwing: CrocheError("network_error", "No HTTP response")); completionHandler(.cancel); return
        }
        var headers: [String: JSON] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key)] = .string(String(describing: value)) }
        sink.yield(.head(status: http.statusCode, headers: headers, expectedLength: response.expectedContentLength))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) { sink(dataTask)?.yield(.body(chunk)) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let sink = lock.withLock { sinks.removeValue(forKey: task.taskIdentifier) }
        if error != nil { sink?.finish(throwing: CrocheError("network_error", "HTTP transport failed")) } else { sink?.finish() }
    }
}
