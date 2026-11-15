import Foundation
import CrocheFFI

public struct BackgroundEvent: Sendable, Equatable {
    /// `delivered`, `deadline`, `cancelled`, `skipped`, or a type this SDK does not know yet.
    public let type: String
    public let at: String?
    /// `skipped`: `storage_unavailable`, or `os_registration_failed` (the OS refused the background
    /// task: on iOS, BGTaskScheduler rejected `ai.croche.background` or it was registered after launch).
    public let reason: String?
    /// The whole event, so an app can log or forward what it does not read.
    public let fields: JSON
    init(_ value: JSON) {
        type = value["type"].string ?? ""; at = value["at"].string; reason = value["reason"].string; fields = value
    }
}

public struct WakeTimes: Sendable, Equatable {
    public struct Wake: Sendable, Equatable { public let user: String; public let at: Double }
    public let wakes: [Wake]
    /// Epoch ms.
    public let next: Double?
}

public struct DueDelivery: Sendable, Equatable {
    public struct Deferred: Sendable, Equatable {
        public let user: String, agent: String, instance: String?
        /// `deadline` or `cancelled` today; open for codes Core adds.
        public let code: String, message: String
    }
    public let ran: Bool
    public let delivered: Int
    public let deferred: [Deferred]
}

/// `debugger.attach`'s options (APP-API `{url, token}`).
public struct DebugAttachOptions: Sendable, Equatable {
    public var url: String
    public var token: String
    public init(url: String, token: String) { self.url = url; self.token = token }
    var json: JSON { .object(["url": .string(url), "token": .string(token)]) }
}

public struct AttachedDebugger: Sendable, Equatable {
    /// The same value as the CLI/broker wire's `attachmentId`, so app logs match CLI logs.
    public let debuggerId: String
    /// `agents.list`, `status`, `history`, `send`, `cancel`, `tools`; open for more.
    public let capabilities: [String]
}

/// The shared-resource factory for one user's session.
public final class Croche: Sendable {
    let core: CoreCroche
    init(core: CoreCroche) { self.core = core }

    /// Opening twice for the same (projectKey, user) is the SAME Core Croche, ref-counted in Core.
    public static func open(_ options: OpenOptions) async throws -> Croche { try await opening(options, nil) }

    /// RECOVERY OPEN (R1), for when `open(options)` fails because the project record is corrupt or
    /// too new (`corrupt_store`, `store_too_new`) or a store refuses writes (`store_full`,
    /// `store_refused`). Only `deleteData()` with an empty scope and `close()` work on the handle;
    /// Core rejects every other member, and any recovery mode it does not know, with `invalid_request`.
    public static func open(_ options: OpenOptions, recovery: RecoveryOptions) async throws -> Croche {
        try await opening(options, recovery)
    }

    private static func opening(_ options: OpenOptions, _ recovery: RecoveryOptions?) async throws -> Croche {
        let open = text(options.json), recoveryJson = recovery.map { text($0.json) }
        let registrations = try (options.tools ?? []).map { try $0.core() }
        #if CROCHE_TEST_HOOKS
        if let serve = FixtureCloud.serve { return try await fixtureOpen(open, registrations, options.storage, recoveryJson, serve) }
        #endif
        let host = try platformHost(), storage = storageArgument(options.storage, host)
        return Croche(core: try await owner({ try CoreCroche.open(openJson: open, registrations: registrations, storage: storage, host: host,
                                                                              bindingFactsJson: BindingFacts.json(), recoveryJson: recoveryJson) },
                                            discard: { try? $0.shutdown() }))
    }

    /// Deletes this user's LOCAL data on the opened Croche. No scope (or an empty one): the declared
    /// stores, registered instances and tool runtime; `agent`: that agent's main and named instances;
    /// `agent` + `instance`: one instance. Core validates every scope. Other users, the install
    /// record, undeclared legacy main stores and Cloud records remain. The Croche stays open; agents
    /// in scope close, and a later `agent()` starts fresh stores. Core owns store locks and partial
    /// progress: retry a failure with the same scope.
    public func deleteData(_ scope: DataScope? = nil) async throws {
        let core = self.core, scope = scope.map { text($0.json) }
        try await blocking { try core.deleteData(scopeJson: scope) }
    }

    /// Call once at launch (iOS: before didFinishLaunching returns). OS identifier `ai.croche.background`.
    public static func registerBackground(_ options: BackgroundOptions = BackgroundOptions()) throws {
        let host = try platformHost(), json = text(options.json)
        do {
            // With the app's store, Core also gets the platform store (its background markers);
            // the default registration hands only the one store (Core: never a second wrapper).
            try coreRegisterBackground(optionsJson: json, sink: options.sink.map(BackgroundSink.init),
                                       storage: storageArgument(options.storage, host),
                                       platformStorage: options.storage.map { _ in PlatformStorageAdapter(host) }, host: host,
                                       bindingFactsJson: BindingFacts.json())
        } catch { throw CrocheError(error) }
    }

    /// When `deliverDue` is next needed (servers, serverless cron). Opens no project.
    public static func wakeTimes(_ options: OpenOptions, before: Double? = nil, after: Double? = nil, limit: Int? = nil) async throws -> WakeTimes {
        var query: [String: JSON] = [:]
        if let before { query["before"] = .number(before) }
        if let after { query["after"] = .number(after) }
        if let limit { query["limit"] = .number(Double(limit)) }
        let open = text(options.json), queryText = query.isEmpty ? nil : text(.object(query))
        let host = try platformHost(), storage = storageArgument(options.storage, host)
        let value = try reply(try await blocking { try coreWakeTimes(openJson: open, queryJson: queryText, storage: storage, host: host) })
        let wakes = try (value["wakes"].array ?? []).map { wake -> WakeTimes.Wake in
            guard let user = wake["user"].string, let at = wake["at"].number else { throw malformed("wake") }
            return WakeTimes.Wake(user: user, at: at)
        }
        return WakeTimes(wakes: wakes, next: value["next"].number)
    }

    /// Delivery and config sync only. Cancel the Task to stop it.
    public func deliverDue() async throws -> DueDelivery {
        let core = self.core
        let value = try reply(try await cancellable { try core.deliverDue(optionsJson: nil, cancel: $0) })
        guard let ran = value["ran"].bool, let delivered = value["delivered"].number else { throw malformed("delivery") }
        let deferred = try (value["deferred"].array ?? []).map { item -> DueDelivery.Deferred in
            guard let user = item["user"].string, let agent = item["agent"].string,
                  let code = item["code"].string, let message = item["message"].string else { throw malformed("deferral") }
            return DueDelivery.Deferred(user: user, agent: agent, instance: item["instance"].string, code: code, message: message)
        }
        return DueDelivery(ran: ran, delivered: Int(delivered), deferred: deferred)
    }

    /// The same instance with the same or no config returns a handle to it; a different config
    /// is Core's `invalid_configuration`.
    public func agent(_ id: String, _ options: AgentOptions? = nil) async throws -> CrocheAgent {
        let core = self.core, scope = options.map { text($0.json) }
        return CrocheAgent(core: try await owner({ try core.agent(id: id, scopeJson: scope) }, discard: { try? $0.shutdown() }))
    }

    public var agentIds: [String] {
        get throws { do { return try core.agentIds() } catch { throw CrocheError(error) } }
    }

    public var wiki: Wiki { Wiki(core: core) }
    public var debugger: Debugger { Debugger(core: core) }

    /// Returns once new work has stopped; the bounded final delivery continues.
    public func close() async throws {
        let core = self.core
        try await blocking { try core.shutdown() }
    }

    /// The project's original documents, in memory for this Croche; put/remove last until close().
    public struct Wiki: Sendable {
        let core: CoreCroche
        public func put(_ doc: WikiDoc) async throws {
            let core = self.core, doc = text(doc.json)
            try await blocking { try core.wikiPut(docJson: doc) }
        }
        public func remove(_ path: String) async throws {
            let core = self.core
            try await blocking { try core.wikiRemove(path: path) }
        }
        public func list() async throws -> [WikiDoc] {
            let core = self.core
            let value = try reply(try await blocking { try core.wikiList() })
            guard let docs = value.array else { throw malformed("wiki list") }
            return try docs.map(WikiDoc.init)
        }
    }

    /// The local debugger: loopback (iproxy), or LAN with the debug key.
    public struct Debugger: Sendable {
        let core: CoreCroche
        public func attach(_ options: DebugAttachOptions) async throws -> AttachedDebugger {
            let core = self.core, options = text(options.json)
            let value = try reply(try await blocking { try core.debugAttach(optionsJson: options) })
            guard let id = value["debuggerId"].string, let capabilities = value["capabilities"].array else { throw malformed("attached debugger") }
            return AttachedDebugger(debuggerId: id, capabilities: capabilities.compactMap(\.string))
        }
        /// The last Croche alias close detaches the runtime.
        public func detach() async throws {
            let core = self.core
            try await blocking { try core.debugDetach() }
        }
    }
}

func malformed(_ what: String) -> CrocheError {
    CrocheError(code: "internal", message: "Core's \(what) is malformed.", category: .internal)
}

/// Core's storage argument: the app's store, else the platform default. Never nil.
func storageArgument(_ storage: (any StoragePal)?, _ host: PlatformPal) -> CoreStoragePal {
    storage.map { CoreStorageAdapter($0) } ?? PlatformStorageAdapter(host)
}

/// Test-only: the OS launch handler table a host gate gives the platform PAL (macOS has none).
enum PlatformBackgroundTesting {
    nonisolated(unsafe) static var launches: (any BackgroundLaunches)?
}

/// The platform PAL (#820 seam): its storage is the default when the app gives none.
func platformHost() throws -> PlatformPal {
    let directory = try NativeProjectFiles.directory(projectDirectory: nil)
    return PlatformPal(directory: directory, secrets: PlatformPal.testingSecrets(directory),
                       backgroundLaunches: PlatformBackgroundTesting.launches ?? PlatformPal.osBackgroundLaunches())
}

/// Background events, at least once, at the next registration in a live runtime. The same
/// delivery protocol as `subscribe` (#830 70a5ca8e): the app's sink runs only after `tryEnter`
/// succeeds, on the main actor, and every entered delivery is completed. The sink cannot throw, so
/// its outcome is always `returned`. An event that is not JSON is an untyped exception Core
/// classifies (no SDK-invented code).
final class BackgroundSink: CoreEventSink, @unchecked Sendable {
    private let sink: @Sendable (BackgroundEvent) -> Void
    init(_ sink: @escaping @Sendable (BackgroundEvent) -> Void) { self.sink = sink }

    func deliver(deliveryId: String, eventJson: String, delivery: CoreDelivery) throws {
        try deliver(eventJson, delivery)
    }

    /// The seam tests drive with a fake gate. Returns the main-actor task.
    @discardableResult
    func deliver(_ eventJson: String, _ delivery: any DeliveryGate) throws -> Task<Void, Never> {
        guard let value = try? JSON(eventJson), value.object != nil else {
            throw MalformedEvent(reason: "a background event must be a JSON object")
        }
        let event = BackgroundEvent(value), sink = self.sink
        return Task { @MainActor in
            guard delivery.tryEnter() else { return }
            sink(event)
            delivery.complete(outcomeJson: EventSinkAdapter.returned)
        }
    }
}
