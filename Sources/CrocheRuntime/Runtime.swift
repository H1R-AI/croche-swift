import Foundation
import CrocheFFI
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

public struct ToolContext: Sendable {
    public let data: JSON
    public let cancellation: RuntimeCancellation
    public var callId: String { data["callId"].string ?? "" }
    public var messageId: String { data["messageId"].string ?? "" }
    /// The opaque user id Croche issued; "" until Cloud has issued it.
    public var userId: String { data["userId"].string ?? "" }
    /// Present when the Runtime config has an agentId.
    public var agentId: String? { data["agentId"].string }
    public var user: String? { data["user"].string }
    public var crocheUserId: String? { data["crocheUserId"].string }
    public var causedBy: [String] { data["causedBy"].array?.compactMap(\.string) ?? [] }
    public var origin: String { data["origin"].string ?? "" }
    /// Where a `withResult` handler leaves its images for this call.
    let images: ImageSink?
    init(data: JSON, cancellation: RuntimeCancellation, images: ImageSink? = nil) {
        self.data = data; self.cancellation = cancellation; self.images = images
    }
}
/// An app command's handler. An async handler must not block its thread: a blocked thread can
/// stall the Runtime's own requests. Await instead, or wrap blocking work in `blockingTool`.
public typealias ToolHandler = @Sendable (_ invocation: JSON, _ context: ToolContext) async throws -> JSON

/// A handler for work that blocks its thread (synchronous I/O, a lock, a sleep). It runs on a
/// thread of its own, never on Swift's cooperative pool, on every OS. The call keeps its slot
/// until `body` returns, however long after a cancel; observe `context.cancellation` to stop.
///
///     tools: ["save": blockingTool { invocation, context in try database.write(invocation) }]
public func blockingTool(_ body: @escaping @Sendable (_ invocation: JSON, _ context: ToolContext) throws -> JSON) -> ToolHandler {
    { invocation, context in
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try body(invocation, context) }) }
            thread.name = "dev.croche.tool"
            thread.start()
        }
    }
}

/// One wiki document: a path such as `menu/stew.md` and its markdown (at most 64 KB; 2,000
/// documents and 8 MB in all). The title is the first `#` heading; optional frontmatter may set
/// `summary`, `keywords` and `agents` (only those agents see the document); `agents` given here
/// overrides the frontmatter's. An agent's own path globs are config: `"wiki": {"include": [...],
/// "exclude": [...]}`.
public struct WikiDocument: Sendable, Equatable {
    public let path: String
    public let markdown: String
    public let agents: [String]?
    public init(path: String, markdown: String, agents: [String]? = nil) {
        self.path = path; self.markdown = markdown; self.agents = agents
    }
}

/// The Croche Runtime for Swift. The Rust Core (crates/croche-ffi) is the Runtime: it holds
/// the state and runs the turn, upkeep, cancellation and persistence. This type exposes it with
/// Swift types; `SwiftHost` performs what only the platform can (the PAL). Pass only
/// serializable Runtime configuration in config.
public actor CrocheRuntime {
    nonisolated let core: CoreRuntime
    let host: SwiftHost
    nonisolated let memoryCache = RuntimeMemoryCache()
    private var closed = false
    var subscriptionHub: StreamHub?
    public nonisolated let logId: String
    #if canImport(UIKit) && os(iOS)
    private var foreground: (any NSObjectProtocol)?
    #endif

    private var onDelivery: (@Sendable (JSON) -> Void)?
    private init(core: CoreRuntime, host: SwiftHost, logId: String) { self.core = core; self.host = host; self.logId = logId }
    private func bind(_ hub: StreamHub) { subscriptionHub = hub }
    /// INTERNAL, not frozen: the React Native bridge's hook (it compiles these sources into its own
    /// module); apps do not use it. `observer` receives the result of each `deliverDue()` that ran a
    /// delivery turn (`ran: true`), whoever called it (the timer, a background run, the foreground,
    /// the app), once the turn is in `inspect()`'s history. Interim: the public subscription for
    /// agent-initiated messages (F25 on #264: `onBackgroundMessage` with replay on open) replaces it.
    @_spi(CrocheBridge)
    public func observeDeliveries(_ observer: (@Sendable (JSON) -> Void)?) { onDelivery = observer }
    /// `secrets` keeps the Runtime credential apart from `storage`: KeychainSecretStore on
    /// Apple platforms. `attestor` proves the genuine app to Cloud when the project requires
    /// it: AppAttestAttestor on a device; nil on a simulator or a host that cannot attest.
    /// `http` replaces the default URLSession transport with one that answers whole requests.
    /// `wiki` is the documents, set at open; this agent's path filter is the config's
    /// `"wiki": {"include": [...], "exclude": [...]}`.
    /// `onEvent` hears one `turn.started` per turn; a send carried into a running turn at a later
    /// model call is `{type:"turn.joined", turnId, inputIds}` (the ids newly carried).
    /// `onUsage` receives every paid call's cost (`{type:"usage", operationId, purpose, causedBy, instance, model,
    /// costUsd, costStatus, tokens?}`; `tokens` holds the reported counts, e.g. `prompt`, `cached`),
    /// `instance` is the named/generated instance key, or null for the main agent.
    /// `purpose` is "model" or "summary"; `causedBy` holds the inputs served (empty for upkeep).
    /// `model` is the gateway-reported answering model (`modelSource: "response"`), or the
    /// request primary when unavailable (`modelSource: "requested"`). `requestedModel` is
    /// present only when different. Reported cost is unchanged by a model substitution.
    /// at least once, from the start: open itself reports a call the process
    /// died during. It runs on a Runtime thread; do not call the Runtime from it.
    /// `scheduler` registers the agent's scheduled notes with the OS for when the app is not
    /// running: `AppRefreshScheduler` (BGTaskScheduler) on iOS; nil elsewhere, where a timer
    /// delivers them while the Runtime is open and the next open delivers what fell due meanwhile.
    /// On iOS the Runtime also calls `deliverDue()` each time the app enters the foreground. A
    /// scheduler whose identifier another open Runtime holds refuses this one
    /// (`scheduler_conflict`).
    /// `projectDirectory` is required on Linux, which has no app-private default.
    /// On Apple platforms it must be nil: the record stays in Application Support.
    public static func create(config: JSON, storage: any RuntimeStorage, secrets: any RuntimeSecretStore,
                              attestor: (any RuntimeAttestor)? = nil,
                              tools: [String: ToolHandler] = [:],
                              http: RuntimeHTTP? = nil,
                              onEvent: (@Sendable (JSON) -> Void)? = nil,
                              onDebugEvent: (@Sendable (JSON) -> Void)? = nil,
                              onUsage: (@Sendable (JSON) -> Void)? = nil,
                              backgroundSync: Bool = true,
                              maintenanceInterval: TimeInterval = 60,
                              wiki: [WikiDocument]? = nil,
                              scheduler: (any RuntimeScheduler)? = nil,
                              projectDirectory: URL? = nil) async throws -> CrocheRuntime {
        let records = try ProjectRecordFiles.forOpen(projectDirectory: projectDirectory)
        let interval = try clampedMaintenanceInterval(maintenanceInterval)
        warnIfReleaseBuildCarriesDebugKey(config)
        var bound = config
        bound["attestationPlatform"] = attestor.map { .string($0.platform) } ?? .null
        let host = SwiftHost(storage: storage, secrets: secrets, attestor: attestor, http: http, tools: tools,
                             background: backgroundSync, scheduler: scheduler, projectRecords: records)
        // The app chose the store, so the Runtime binds its identity to it (a custom storage key).
        let options = RuntimeOpenOptions(storageKey: "croche.swift", streaming: config["streaming"].bool ?? true,
                                         backgroundSync: backgroundSync,
                                         maintenanceIntervalMs: interval * 1000)
        let configText = String(decoding: try bound.encoded(), as: UTF8.self)
        let listener = onEvent.map { EventHook($0) }
        let usage = onUsage.map { EventHook($0) }
        try host.attachScheduler()
        // From here the host's stop (close, or a failed open) detaches the scheduler, once.
        let core: CoreRuntime
        do { core = try await offload { try CoreRuntime.open(pal: host, config: configText, options: options, onEvent: listener, onUsage: usage) } }
        catch { host.stop(); host.session.close(); throw error }
        if let onDebugEvent { try? core.setDebugObserver(observer: EventHook(onDebugEvent), full: false) }
        let hub: StreamHub
        do { hub = try await offload { try StreamHub(port: FFIStreamPort(core: core)) } }
        catch { _ = try? await offload { core.close(); return true }; host.stop(); host.session.close(); throw error }
        let runtime = CrocheRuntime(core: core, host: host, logId: hub.logId)
        await runtime.bind(hub)
        try await runtime.refreshMemory()
        host.deliver = { [weak runtime] in _ = try? await runtime?.deliverDue() }
        host.attach(core)
        #if canImport(UIKit) && os(iOS)
        await runtime.observeForeground()
        #endif
        if let wiki {
            do { try await runtime.wiki.set(wiki) } catch { try? await runtime.close(); throw error }
        }
        return runtime
    }
    /// Adopts the Core returned by CoreProject; it never opens a second Runtime.
    static func adopt(core: CoreRuntime, host: SwiftHost) async throws -> CrocheRuntime {
        let hub: StreamHub
        do { hub = try await offload { try StreamHub(port: FFIStreamPort(core: core)) } }
        catch { _ = try? await offload { core.close(); return true }; host.stop(); host.session.close(); throw error }
        let runtime = CrocheRuntime(core: core, host: host, logId: hub.logId)
        await runtime.bind(hub)
        try await runtime.refreshMemory()
        host.deliver = { [weak runtime] in _ = try? await runtime?.deliverDue() }
        host.attach(core)
        #if canImport(UIKit) && os(iOS)
        await runtime.observeForeground()
        #endif
        return runtime
    }

    func refreshMemory() async throws { memoryCache.set(try inspect()["memory"]) }

    /// The founder's condition for debug keys: never silent in a shipped build.
    static func warnIfReleaseBuildCarriesDebugKey(_ config: JSON) {
        #if !DEBUG
        if config["debugKey"].string != nil {
            FileHandle.standardError.write(Data("[Croche] A debug key (debugKey) is set in a RELEASE build. It admits any install of this project without App Attest and must not ship.\n".utf8))
        }
        #endif
    }
    public static func identity(config: JSON) throws -> JSON {
        do { return publicStorageIdentity(try JSON(ffiIdentity(String(decoding: try config.encoded(), as: UTF8.self)))) }
        catch { throw CrocheError(error) }
    }
    /// The Runtime's calls block their thread while the host performs effects: run them on a
    /// thread of their own, never on the cooperative pool or the main thread.
    /// Croche's own tests: runs first on each offload thread, so a test can delay it the way the
    /// OS may (#346). Nil in every app.
    nonisolated(unsafe) static var offloadStarting: (@Sendable () -> Void)?
    static func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                offloadStarting?()
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: CrocheError(error)) }
            }
        }
    }
    fileprivate static func offloaded<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await offload(body)
    }
    fileprivate func run(_ body: @escaping @Sendable (CoreRuntime) throws -> String) async throws -> JSON {
        guard !closed else { throw CrocheError("closed", "Runtime is closed") }
        let core = self.core
        return try JSON(try await Self.offload { try body(core) })
    }
    /// Runs one turn. Cancelling the calling Task cancels this turn only (from any thread, never
    /// missed): it ends `cancelled`, keeping what was said and charging an unanswered call.
    /// `responseFormat`: structured output, OpenAI's shape (`{"type":"json_schema",...}` or
    /// `{"type":"json_object"}`); the result's `output` is the reply as JSON the Core checked.
    ///
    /// Sends are admitted in the order the calls reach the Runtime (one task's sends in program
    /// order): that order is their place among held sends and in a turn they share.
    /// `imageResolution`: for every image that does not name its own (default standard).
    public func send(_ input: JSON, responseFormat: JSON? = nil, imageResolution: ImageResolution? = nil) async throws -> JSON {
        guard !closed else { throw CrocheError("closed", "Runtime is closed") }
        // Admitted here, on the actor, before the hop to a thread of its own.
        return try await beginSend(input, responseFormat: responseFormat, imageResolution: imageResolution).result()
    }
    /// Admits a send at once on the calling thread, without waiting for its turn: for a host
    /// that must fix the order of sends before hopping threads (the React Native bridge).
    nonisolated func beginSend(_ input: JSON, responseFormat: JSON? = nil, imageResolution: ImageResolution? = nil) throws -> PendingTurn {
        // Standard images are re-encoded here, before admission, so sends keep their order.
        let input = Images.prepareInput(input, fallback: imageResolution)
        let text = String(decoding: try input.encoded(), as: UTF8.self)
        let format = try responseFormat.map { String(decoding: try $0.encoded(), as: UTF8.self) }
        let token = CancelToken()
        do { return PendingTurn(try core.beginSend(input: text, cancel: token, responseFormat: format), token) }
        catch { throw CrocheError(error) }
    }
    public func sync() async throws -> JSON { try await run { try $0.sync(); return "null" } }
    /// One round of background upkeep: deliver the outbox of call reports, then sync balances,
    /// policy and the model key. The Core does work only when some is due and backs off after
    /// a failure. It runs by itself after each turn and on a timer (backgroundSync); call it
    /// when the app returns to the foreground. It never delays a turn: a send takes over
    /// while it waits on Cloud. Never throws; the result says what happened.
    @discardableResult
    public func maintain(force: Bool = false) async -> JSON {
        (try? await run { $0.maintain(force: force) }) ?? .object(["ran": .bool(false)])
    }
    /// Delivers the agent's scheduled notes that are due, as one turn: `{ran: false}` when none
    /// is (no turn, no cost) or one is already being delivered, else `{ran, ids, delivered, turn}`.
    /// Never before a note's time. The iOS Runtime calls it at every foreground; elsewhere, call
    /// it when the app returns.
    ///
    /// Cancelling the calling Task cancels this delivery only: waiting behind another turn, it
    /// leaves without running; running, its turn stops. Either way its notes stay pending.
    /// Cancelled after the delivery ended, nothing happens: never another turn (`cancel()` stops
    /// whatever turn runs).
    ///
    /// Afterwards the pending set is handed to the OS scheduler again (a refusal is reported as
    /// `schedule.degraded`): the OS spends a request when it runs it, and a delivery cut short
    /// leaves its notes. Not after an `inFlight` answer: the delivery in flight does that when it
    /// ends. A failed delivery that answers `retryAt` waits until then.
    @discardableResult
    public func deliverDue() async throws -> JSON {
        guard !closed else { throw CrocheError("closed", "Runtime is closed") }
        host.attempted()
        let core = self.core
        let token = CancelToken()
        let result: JSON
        do {
            result = try await withTaskCancellationHandler {
                try JSON(try await Self.offload { try core.deliverDue(cancel: token) })
            } onCancel: { token.cancel() }
        } catch { await resync(); throw error }
        if result["inFlight"].bool == true { return result }
        if let retry = retryAt(result["retryAt"]) { host.retryAfter(retry) }
        await resync()
        if result["ran"].bool == true { onDelivery?(result) }
        return result
    }
    /// Hands the pending set to the OS scheduler again, through the Core, which reports a refusal
    /// as `schedule.degraded`.
    private func resync() async {
        guard !closed else { return }
        let core = self.core
        _ = try? await Self.offload { try core.reschedule(); return true }
    }
    #if canImport(UIKit) && os(iOS)
    private func observeForeground() {
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                            object: nil, queue: nil) { [weak self] _ in
            Task { _ = try? await self?.deliverDue() }
        }
    }
    #endif
    /// The agent's pending scheduled notes: `{pending: [{id, at, note}], due}`.
    public func schedules() async throws -> JSON { try await run { try $0.schedules() } }
    public func flush() async throws -> JSON { try await run { try $0.flush(); return "null" } }
    /// Forgets this user's conversation and memory and starts over (money and identity stay).
    /// The clear takes its place on the actor, as `send` does: behind a running turn, ahead of
    /// every send that reaches the Runtime after it. Only the wait for it is on a thread of its own.
    public func clearHistory() async throws {
        guard !closed else { throw CrocheError("closed", "Runtime is closed") }
        if let subscriptionHub { try await subscriptionHub.clearHistory(); return }
        try await Self.finish(beginClearHistory())
    }
    /// Admits a clear at once on the calling thread, for a host that must fix its order against
    /// sends before hopping threads (the React Native bridge); `finish` then waits for it.
    nonisolated func beginClearHistory() -> PendingClear { core.beginClearHistory() }
    /// Waits for an admitted clear on a thread of its own.
    static func finish(_ pending: PendingClear) async throws {
        _ = try await offload { try pending.finish(); return true }
    }
    /// Asks Cloud to raise (or, `absolute`, set) this user's allowance within the project's
    /// ceilings. Pass `id` (e.g. the purchase id) to make a retry safe: Cloud applies it once.
    /// Called while another operation runs, it answers `{deferred: true}` at once instead (see
    /// `WriteResult`).
    public func adjustBudget(_ amount: Double, absolute: Bool = false, id: String? = nil) async throws -> JSON {
        try await run { try $0.adjustBudget(amount: amount, absolute: absolute, id: id) }
    }
    /// Internal until `memory history` (B3): turns `from...to` from the turn archive, as
    /// `{"records":[...]}`; `archive_unavailable` when the storage keeps none.
    func archiveRead(from: UInt64, to: UInt64) async throws -> JSON {
        try await run { try $0.archiveRead(from: from, to: to) }
    }
    /// Internal: deletes archived turns, every one without a range.
    func archiveClear(from: UInt64? = nil, to: UInt64? = nil) async throws {
        _ = try await run { try $0.archiveClear(from: from, to: to); return "null" }
    }
    public func inspect() throws -> JSON {
        guard !closed else { throw CrocheError("closed", "Runtime is closed") }
        do { return try JSON(try core.inspect()) } catch { throw CrocheError(error) }
    }
    /// Replaces the tool list (metadata as in config `tools`) and their handlers, as on the web.
    /// The Core validates it at once, all or nothing (a refusal changes nothing); the swap takes
    /// its place in the queue, so turns sent before it still offer the old list. A removed or
    /// changed command answers `withdrawn` once the swap applies. A handler given here also
    /// serves turns already queued under the same name.
    public func setTools(_ tools: JSON, handlers: [String: ToolHandler]) throws {
        guard !closed else { throw CrocheError("closed", "Runtime is closed") }
        let text = String(decoding: try tools.encoded(), as: UTF8.self)
        // New names first: the Core cannot call them before it accepts the list. Replacements
        // only after it accepts; a refusal removes what it staged, so every handler is as it was.
        let stamp = host.stageTools(handlers)
        do { try core.setToolDeclarations(tools: text) } catch { host.unstageTools(handlers.keys, stamp: stamp); throw CrocheError(error) }
        host.acceptTools(handlers)
    }
    /// The tool list the model is offered (metadata only).
    public func tools() throws -> JSON { try inspect()["tools"] }
    /// Stops the running turn only: messages sent while it ran still go, together, as the next
    /// turn. Cancelling a send's Task drops just that send while it is held; once its turn has
    /// started, the turn stops, for every send it carries.
    public func cancel() { core.cancelTurn() }
    /// Drops the messages held behind the running turn (each send ends `cancelled`); returns how many.
    /// Resolves once the held record no longer lists them.
    @discardableResult public func clearQueued() async throws -> Int {
        guard !closed else { return 0 }
        let core = self.core
        return Int(try await Self.offload { try core.clearQueued() })
    }
    /// Long-term memory: `snapshot()` for a read-only view, the other methods to manage it.
    public nonisolated var memory: CrocheMemory { CrocheMemory(runtime: self) }
    /// The app's knowledge documents, held by the Rust Core in memory (never stored: load them
    /// on each open). The model searches and reads them with the built-in `wiki` command;
    /// `list`, `read` and `search` here are that same view.
    public nonisolated var wiki: CrocheWiki { CrocheWiki(runtime: self) }
    /// Closing never waits on Cloud: unsent reports stay in the outbox for the next open. A paid
    /// call upkeep has in flight is finished and settled first.
    /// The Core projection fence does not await buffered AsyncStream/UI consumers.
    /// An app callback that waits for work on the closer's thread deadlocks under any
    /// wait-for-callback fence. A synchronous Core-listener self-close does not wait on itself.
    public func close() async throws {
        if closed { return }
        closed = true
        memoryCache.close()
        subscriptionHub?.close()
        host.stop()
        #if canImport(UIKit) && os(iOS)
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
        foreground = nil
        #endif
        let core = self.core
        _ = try await Self.offload { core.close(); return true }
        // After the Core: a paid call upkeep has in flight is finished first.
        host.session.close()
    }
}

/// `runtime.memory`: this person's long-term memory, as the TS SDK's `runtime.memory`.
public struct CrocheMemory: Sendable {
    fileprivate let runtime: CrocheRuntime
    /// The memory part of `inspect()`.
    public func callAsFunction() -> JSON { runtime.memoryCache.value }
    public func snapshot() async throws -> JSON { try await runtime.refreshMemory(); return callAsFunction() }
    private func refreshed(_ body: @escaping @Sendable (CoreRuntime) throws -> String) async throws -> JSON {
        let result = try await runtime.run(body)
        if result["deferred"].bool != true { try? await runtime.refreshMemory() }
        return result
    }
    /// AI-written facts with ids, turn/time stamps, refs and replacement links.
    public func list() async throws -> JSON { try await refreshed { try $0.memoryList() } }
    /// `{deleted}`, or `{deferred: true}` (see `WriteResult`).
    @discardableResult
    public func delete(_ id: String) async throws -> JSON { try await refreshed { try $0.memoryDelete(id: id) } }
    /// Removes every AI-written fact; the summary and conversation stay. `{cleared}`, or
    /// `{deferred: true}` (see `WriteResult`).
    @discardableResult
    public func clear() async throws -> JSON { try await refreshed { try $0.memoryClear() } }
    /// Turns memory on or off for this person; the choice outlives `clearHistory()`. Applied, it
    /// carries the setting now in force.
    @discardableResult
    public func enabled(_ on: Bool) async throws -> WriteResult<Bool> {
        WriteResult(try await refreshed { try $0.memorySetEnabled(enabled: on) }) { _ in on }
    }
    /// Current and replaced AI-written facts: `{enabled, items}`, not the summary.
    public func export() async throws -> JSON { try await refreshed { try $0.memoryExport() } }
    /// Replaces the observer of every `memory.changed` (the app's, the model's, upkeep's).
    public func onChanged(_ listener: (@Sendable (MemoryChangedEvent) -> Void)?) throws {
        guard !runtime.memoryCache.closed else { throw CrocheError("closed", "The agent is closed.") }
        do {
            runtime.core.setMemoryObserver(observer: listener.map { callback in EventHook { event in
                Task { try? await runtime.refreshMemory() }
                callback(event)
            } })
        }
    }
}

extension WikiDocument {
    /// The `.md` files under `directory` as wiki documents, paths relative to it with `/`
    /// (`menu/stew.md`), in name order. Subfolders are read; symbolic links and other files are
    /// skipped, as the other SDKs' loaders do.
    public static func fromDirectory(_ directory: URL) throws -> [WikiDocument] {
        let files = FileManager.default
        var out: [WikiDocument] = []
        func walk(_ dir: URL, _ prefix: String) throws {
            let names: [String]
            do { names = try files.contentsOfDirectory(atPath: dir.path).sorted() }
            catch { throw CrocheError("invalid_wiki", "\(dir.path): \(error.localizedDescription)") }
            for name in names {
                let url = dir.appendingPathComponent(name)
                let path = prefix.isEmpty ? name : prefix + "/" + name
                // attributesOfItem does not follow a link, so a link is neither a folder nor a file.
                let type = (try? files.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                if type == .typeDirectory {
                    try walk(url, path)
                } else if type == .typeRegular && name.hasSuffix(".md") {
                    if out.count >= 2000 { throw CrocheError("invalid_wiki", "The wiki holds at most 2000 documents") }
                    out.append(WikiDocument(path: path, markdown: String(decoding: try Data(contentsOf: url), as: UTF8.self)))
                }
            }
        }
        try walk(directory, "")
        return out
    }
    /// The documents in a folder shipped with the app (added to the target as a folder
    /// reference, so its subfolders survive): `WikiDocument.fromBundle()` reads `wiki/`.
    public static func fromBundle(_ bundle: Bundle = .main, folder: String = "wiki") throws -> [WikiDocument] {
        guard let url = bundle.url(forResource: folder, withExtension: nil) else {
            throw CrocheError("invalid_wiki", "No folder \(folder) in the bundle: add it to the target as a folder reference.")
        }
        return try fromDirectory(url)
    }
}

/// `runtime.wiki`: the app's documents, as the TS SDK's `runtime.wiki`.
public struct CrocheWiki: Sendable {
    fileprivate let runtime: CrocheRuntime
    private static func json(_ docs: [WikiDocument]) throws -> String {
        let value = JSON.array(docs.map { doc in
            var o: [String: JSON] = ["path": .string(doc.path), "markdown": .string(doc.markdown)]
            if let agents = doc.agents { o["agents"] = .array(agents.map { .string($0) }) }
            return .object(o)
        })
        return String(decoding: try value.encoded(), as: UTF8.self)
    }
    /// Replaces every document and answers what it installed: `{documents, bytes, digest}`.
    /// On an error nothing changes.
    @discardableResult
    public func set(_ docs: [WikiDocument]) async throws -> JSON {
        let text = try Self.json(docs)
        return try await runtime.run { try $0.wikiSet(docs: text) }
    }
    /// `set`, without the digest.
    public func load(_ docs: [WikiDocument]) async throws { try await set(docs) }
    /// This user's own documents (saved recipes, lesson notes): stored with their state (at most
    /// 200 documents and 256 KB as stored), under `user/` (which the app's may not use), and durable when
    /// this returns. `clearHistory` keeps them. To share one with another character, put it to that character's Runtime too.
    /// Answers `{documents, bytes}`, or `{deferred: true}` (see `WriteResult`).
    @discardableResult
    public func putUser(_ docs: [WikiDocument]) async throws -> JSON {
        let text = try Self.json(docs)
        return try await runtime.run { try $0.wikiPutUser(docs: text) }
    }
    /// Removes one of this user's own documents; whether it existed.
    @discardableResult
    public func removeUser(_ path: String) async throws -> WriteResult<Bool> {
        WriteResult(try await runtime.run { try $0.wikiRemoveUser(path: path) }) { $0["removed"].bool ?? false }
    }
    /// Removes every one of this user's own documents; how many.
    @discardableResult
    public func clearUser() async throws -> WriteResult<Int> {
        WriteResult(try await runtime.run { try $0.wikiClearUser() }) { Int($0["cleared"].number ?? 0) }
    }
    /// Adds documents or replaces those with the same path, atomically.
    public func put(_ docs: [WikiDocument]) async throws {
        let text = try Self.json(docs)
        _ = try await runtime.run { try $0.wikiPut(docs: text); return "null" }
    }
    /// Whether the document existed.
    @discardableResult
    public func remove(_ path: String) async throws -> Bool {
        try await runtime.run { try $0.wikiRemove(path: path) ? "true" : "false" }.bool ?? false
    }
    /// `[{path, title, summary?, characters, parts}]` under `folder` (every document when nil).
    public func list(folder: String? = nil) async throws -> JSON { try await runtime.run { try $0.wikiList(folder: folder) } }
    /// One part (1-based) of a document, `{path, title, part, parts, text}`; `.null` when none.
    public func read(_ path: String, part: Int = 1) async throws -> JSON {
        try await runtime.run { try $0.wikiRead(path: path, part: UInt32(clamping: max(0, part))) }
    }
    /// The best matches, best first: at most `limit` (and 5).
    public func search(_ query: String, limit: Int = 5) async throws -> JSON {
        try await runtime.run { try $0.wikiSearch(query: query, limit: UInt32(clamping: min(max(0, limit), 5))) }
    }
}

/// What a write (memory, this user's own documents, the allowance) answers: `.applied`, with what
/// it did, or `.deferred`: it was called while another operation ran, was accepted, and applies in
/// call order when that operation ends. A message sent after the write sees it; one sent before
/// does not. It is held in this process until then: closing first drops it, and a write that
/// cannot apply then is reported as a `write.failed` debug event.
public enum WriteResult<Value: Sendable>: Sendable {
    case applied(Value)
    case deferred

    init(_ answer: JSON, _ applied: (JSON) -> Value) {
        self = answer["deferred"].bool == true ? .deferred : .applied(applied(answer))
    }
}
extension WriteResult: Equatable where Value: Equatable {}

/// A send `beginSend` admitted. Its result, once: `result()` blocks a thread of its own, and
/// cancelling the awaiting Task cancels this send only.
final class PendingTurn: Sendable {
    private let pending: PendingSend
    private let token: CancelToken
    fileprivate init(_ pending: PendingSend, _ token: CancelToken) { self.pending = pending; self.token = token }
    func result() async throws -> JSON {
        let pending = self.pending
        return try await withTaskCancellationHandler {
            try JSON(try await CrocheRuntime.offloaded { try pending.wait() })
        } onCancel: { [token] in token.cancel() }
    }
    func cancel() { token.cancel() }
}

final class RuntimeMemoryCache: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    var closed: Bool { lock.withLock { ended } }
    func close() { lock.withLock { ended = true } }
    private var snapshot: JSON = .object(["enabled": .bool(true), "text": .string(""), "updatedAt": .null, "compactedTurns": .number(0), "items": .array([])])
    var value: JSON { lock.withLock { snapshot } }
    func set(_ value: JSON) { lock.withLock { snapshot = value } }
}
