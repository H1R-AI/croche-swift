import Foundation
import CrocheFFI

/// Opens a declared agent's main store, or one of its instances. `config` is an app-supplied
/// patch, the final layer over the definition's applied configuration; it needs an `instance`
/// and is never stored, so pass it on every open. `handlers` run the tools a patch adds.
struct LegacyAgentOptions: Sendable {
    var instance: String?
    var config: JSON?
    var handlers: [String: ToolHandler]
    init(instance: String? = nil, config: JSON? = nil, handlers: [String: ToolHandler] = [:]) {
        self.instance = instance; self.config = config; self.handlers = handlers
    }
    /// Handler callbacks never enter JSON: Core receives their names for its census.
    var json: JSON {
        var value: [String: JSON] = [:]
        if let instance { value["instance"] = .string(instance) }
        if let config { value["config"] = config }
        if config != nil || !handlers.isEmpty { value["handlers"] = .array(handlers.keys.sorted().map(JSON.string)) }
        return .object(value)
    }
}

/// One of a declared agent's instances for this project's user.
struct InstanceInfo: Sendable, Equatable {
    /// Core's `[{instance}]`. A malformed listing fails typed (`core_error`); a key is never read as "".
    static func listing(_ text: String) throws -> [InstanceInfo] {
        guard let list = try JSON(text).array else { throw LegacyCrocheError("core_error", "Core's instance listing is not a list.") }
        return try list.map { InstanceInfo(instance: try required($0, "instance", "instance listing")) }
    }
    let instance: String
    init(instance: String) { self.instance = instance }
}

/// What `deleteData` deletes for this project's user: with no fields, the declared main stores and
/// every registered instance; with `agent`, that agent's; with `agent` and `instance`, that instance.
struct DeleteDataOptions: Sendable {
    var agent: String?
    var instance: String?
    init(agent: String? = nil, instance: String? = nil) { self.agent = agent; self.instance = instance }
    var json: JSON {
        var value: [String: JSON] = [:]
        if let agent { value["agent"] = .string(agent) }
        if let instance { value["instance"] = .string(instance) }
        return .object(value)
    }
}

/// A required string in a Core reply. A missing one is a Core bug, so it fails, never as "".
private func required(_ value: JSON, _ key: String, _ what: String) throws -> String {
    guard let text = value[key].string else { throw LegacyCrocheError("core_error", "Core's \(what) has no \(key).") }
    return text
}

/// The local resolved view: the full resolved app configuration (an AgentConfig), never host or
/// user fields. Revision values are opaque: compare them for equality only; the effective and
/// patch revisions are meaningful within the same Core version.
struct EffectiveAgentConfig: Sendable, Equatable {
    /// The resolved AgentConfig.
    let config: JSON
    /// Opaque identity of the full resolved app configuration, before host or user fields.
    let effectiveRevision: String
    /// Opaque identity of the selected bundled or released project snapshot.
    let revisionId: String
    /// Opaque identity of this instance's config patch; nil without a patch.
    let patchRevision: String?
    init(config: JSON, effectiveRevision: String, revisionId: String, patchRevision: String?) {
        self.config = config; self.effectiveRevision = effectiveRevision; self.revisionId = revisionId; self.patchRevision = patchRevision
    }
}

/// Known agent error codes; other Core and host codes reach `CrocheError.code` verbatim.
enum CrocheErrorCode {
    /// The instance is open with another config patch.
    static let agentConflict = "agent_conflict"
    static let invalidConfiguration = "invalid_configuration"
}

typealias ProjectToolContext = LegacyToolContext
typealias ProjectUsageEvent = JSON
typealias RuntimeDebugEvent = JSON
typealias MemoryChangedEvent = JSON

/// The project-returned agent uses the existing Runtime's port, subscriptions and memory.
final class LegacyCrocheAgent: Sendable {
    private let core: CoreRuntime
    private let runtime: AgentEngine
    private let lifetime = ProjectAgentLifetime()
    private let hub: StreamHub
    var engine: AgentEngine { runtime }
    let id: String
    let instance: String?
    let created: Bool
    let logId: String
    init(core: CoreRuntime, runtime: AgentEngine, hub: StreamHub) {
        self.hub = hub
        self.core = core; self.runtime = runtime
        id = core.agentId(); instance = core.instance(); created = core.created(); logId = runtime.logId
    }
    var name: String? { core.name() }
    var mode: String? { core.mode() }
    var visibleTools: [String]? { core.visibleTools() }
    func effectiveConfig() throws -> EffectiveAgentConfig {
        let core = self.core
        let value: JSON
        do { value = try JSON(core.effectiveConfig()) } catch { throw LegacyCrocheError(error) }
        guard value["config"].object != nil else { throw LegacyCrocheError("core_error", "Core's effective config has no config.") }
        return EffectiveAgentConfig(config: value["config"], effectiveRevision: try required(value, "effectiveRevision", "effective config"),
                                    revisionId: try required(value, "revisionId", "effective config"), patchRevision: value["patchRevision"].string)
    }
    /// Closed by `close()`, by the project, or by Core (`deleteData` closes the agents in its scope).
    var closed: Bool { lifetime.closed || core.isClosed() }
    var memory: CrocheMemory { runtime.memory }
    private func check() throws { if closed { throw LegacyCrocheError("closed", "The agent is closed.") } }
    func setTools(_ visible: [String]?) async throws {
        try check(); let core = self.core
        _ = try await Offload.run { try core.setTools(visible: visible); return true }
    }
    func setMode(_ mode: String?) async throws {
        try check(); let core = self.core
        _ = try await Offload.run { try core.setMode(mode: mode); return true }
    }
    /// Core's config sync, for Croche's own tests. Not public: Core refreshes before any money
    /// refusal, so an app never syncs by hand (APP-API: sync() removed).
    func sync() async throws { try check(); _ = try await runtime.sync() }
    /// SDK shorthand only; Core generates the id and validates the request.
    func send(_ text: String, _ options: SendOptions = SendOptions()) async throws -> LegacyReceipt {
        try await send(SendInput(input: [.text(text, kind: .user)]), options)
    }
    func send(_ input: SendInput, _ options: SendOptions = SendOptions()) async throws -> LegacyReceipt {
        try check(); return try await runtime.send(input, options: options)
    }
    func request(_ input: SendInput, _ options: RequestOptions = RequestOptions()) async throws -> LegacyRequestResult {
        try check()
        let result = try await runtime.request(input, options: SendOptions(responseFormat: options.responseFormat), wait: options.wait)
        try? await runtime.refreshMemory()
        return result
    }
    func subscribe(_ options: LegacySubscribeOptions) -> Subscription { hub.subscribe(options) }
    func cancel(_ id: String? = nil) async throws {
        try check()
        if let id { try await runtime.cancel(id) }
        else {
            let core = self.core
            _ = try await Offload.run { core.cancelTurn(); return true }
        }
    }
    func clearHistory() async throws { try check(); try await runtime.clearHistory(); try? await runtime.refreshMemory() }
    func close() async throws {
        let task = lifetime.close { try await self.runtime.close() }
        try await task.value
    }
}

private final class ProjectAgentLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closing: Task<Void, Error>?
    var closed: Bool { lock.withLock { closing != nil } }
    func close(_ body: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        lock.withLock {
            if let closing { return closing }
            let task = Task { try await body() }; closing = task; return task
        }
    }
}

// Internal host construction, shared by platform-owned storage and host tests.
struct NativeProjectOptions: Sendable {
    var host: JSON
    var bundledConfig: JSON
    var user: String?
    var language: String?
    var handlers: [String: ToolHandler] = [:]
    var streaming = true
    var backgroundSync = true
    var maintenanceIntervalMs = 60_000.0
    var storage: @Sendable (String) -> any RuntimeStorage
    var secretStorage: @Sendable (String) -> any RuntimeSecretStore
    var attestor: (any RuntimeAttestor)?
    var fetch: RuntimeHTTP?
    var timeZone: TimeZone?
    var records: @Sendable () -> ProjectRecordFiles
    var onUsage: (@Sendable (JSON) -> Void)?
    var onDebugEvent: (@Sendable (JSON) -> Void)?
}

final class NativeProjectPals: HostPalFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String: SwiftHost] = [:]
    private var all: [SwiftHost] = []
    /// The in-flight open's own handlers and its definition id (nil: the default agent). The
    /// session serializes opens, so at most one table is staged.
    private var staged: (id: String?, handlers: [String: ToolHandler])?
    let options: NativeProjectOptions
    init(_ options: NativeProjectOptions) { self.options = options }
    func pal(agent: String) -> any HostPal {
        let options = self.options
        let slot = NativeProjectSlot.storageLabel(agent)
        // An open's own handlers bind by definition id while it is in flight (the session serializes opens).
        let id = NativeProjectSlot.isMaintenance(agent) ? nil : ((try? JSON(agent).array?.first?.string) ?? agent)
        let own = lock.withLock { () -> [String: ToolHandler] in
            guard let id, let staged, staged.id == nil || staged.id == id else { return [:] }
            return staged.handlers
        }
        let handlers = tools(own)
        // A fresh host for every request: record and default-agent PALs are separate.
        let host = SwiftHost(storage: options.storage(slot), secrets: options.secretStorage(slot),
            attestor: options.attestor, http: options.fetch, tools: handlers,
            background: options.backgroundSync, projectRecords: options.records())
        host.timeZone = options.timeZone
        lock.withLock { if !NativeProjectSlot.isMaintenance(agent) { hosts[agent] = host }; all.append(host) }
        return host
    }
    func stage(_ id: String?, _ handlers: [String: ToolHandler]) { lock.withLock { staged = (id, handlers) } }
    func unstage() { lock.withLock { staged = nil } }
    /// The project's handlers plus an instance's own (Core refuses a shadowing name), with the
    /// project tool context.
    private func tools(_ own: [String: ToolHandler]) -> [String: ToolHandler] {
        let options = self.options
        return options.handlers.merging(own) { _, child in child }.mapValues { handler -> ToolHandler in
            { invocation, context in
                var data = context.data.object ?? [:]
                let issued = data.removeValue(forKey: "userId")?.string
                data["user"] = options.user.map(JSON.string) ?? .null
                data["crocheUserId"] = issued.flatMap { $0.isEmpty ? nil : $0 }.map(JSON.string) ?? .null
                // The throw goes to Core as it is (APP-API: the tool_failed remap is Core's); the
                // host's own "nothing ran" rule (handlerError) still applies on the way out.
                return try await handler(invocation, LegacyToolContext(data: .object(data), cancellation: context.cancellation, images: context.images))
            }
        }
    }
    /// Latest successful open wins: that instance slot's future invocations use these handlers.
    func rebind(_ slot: String, _ own: [String: ToolHandler]) throws { try host(slot).replaceTools(tools(own)) }
    func host(_ slot: String) throws -> SwiftHost {
        try lock.withLock {
            guard let host = hosts[slot] else { throw LegacyCrocheError("core_error", "Core opened an agent without requesting its host.") }
            return host
        }
    }
    func stop() {
        let stopped = lock.withLock { () -> [SwiftHost] in
            defer { all.removeAll(); hosts.removeAll() }; return all
        }
        for host in stopped { host.stop(); host.session.close() }
    }
}

/// Core owns configuration selection, agent census, instances, locks and project identity.
final class LegacyCroche: Sendable {
    private let core: CoreProject
    private let pals: NativeProjectPals
    private let session: NativeProjectSession
    private init(core: CoreProject, pals: NativeProjectPals) {
        self.core = core; self.pals = pals; session = NativeProjectSession(core: core, pals: pals)
    }
    var user: String? { core.user() }
    var installationId: String? { core.installationId() }
    var crocheUserId: String? { core.crocheUserId() }
    var agentIds: [String] { core.agentIds() }
    var applied: JSON { (try? JSON(core.applied())) ?? .null }
    static func open(_ options: LegacyOpenOptions) async throws -> LegacyCroche {
        let native = try await Offload.run { try options.native() }
        return try await open(native)
    }
    static func open(_ options: NativeProjectOptions) async throws -> LegacyCroche {
        AgentEngine.warnIfReleaseBuildCarriesDebugKey(options.host)
        let pals = NativeProjectPals(options)
        let context = ProjectObserverContext(user: options.user)
        var host = options.host
        if let attestor = options.attestor { host["attestationPlatform"] = .string(attestor.platform) }
        let wire = ProjectOpenOptions(host: try projectText(host), user: options.user,
            bundledConfig: try projectText(options.bundledConfig), handlers: Array(options.handlers.keys), language: options.language,
            streaming: options.streaming, backgroundSync: options.backgroundSync,
            maintenanceIntervalMs: options.maintenanceIntervalMs)
        do {
            let core = try await Offload.run {
                try CoreProject.open(pals: pals, options: wire, onUsage: options.onUsage.map { listener in EventHook { listener(context.usage($0)) } },
                                     onDebug: options.onDebugEvent.map(EventHook.init))
            }
            context.attach(core)
            return LegacyCroche(core: core, pals: pals)
        } catch { pals.stop(); throw error }
    }
    func agent(_ id: String? = nil, _ options: LegacyAgentOptions = LegacyAgentOptions()) async throws -> LegacyCrocheAgent {
        try await session.agent(id, options)
    }
    /// This user's instances of a declared agent, sorted by key.
    func listInstances(_ id: String) async throws -> [InstanceInfo] {
        let core = self.core
        let text = try await Offload.run { try core.listInstances(agentId: id) }
        return try InstanceInfo.listing(text)
    }
    /// Deletes this user's stores on this device. Core first closes this project's open agents in
    /// scope; a store open elsewhere fails `store_busy` and nothing is deleted.
    func deleteData(_ options: DeleteDataOptions = DeleteDataOptions()) async throws {
        try await session.deleteData(options)
    }
    func close() async throws { try await session.close() }
}

private actor NativeProjectSession {
    private let core: CoreProject
    private let pals: NativeProjectPals
    private var agents: [String: LegacyCrocheAgent] = [:]
    private var closing: Task<Void, Error>?
    private var admission: Task<Void, Never>?
    init(core: CoreProject, pals: NativeProjectPals) { self.core = core; self.pals = pals }
    func agent(_ id: String? = nil, _ options: LegacyAgentOptions = LegacyAgentOptions()) async throws -> LegacyCrocheAgent {
        try await admit { try await self.openAgent(id, options: options) }
    }
    func deleteData(_ options: DeleteDataOptions) async throws {
        guard closing == nil else { throw LegacyCrocheError("closed", "The project is closed.") }
        let core = self.core, text = try projectText(options.json)
        var failure: Error?
        do { _ = try await Offload.run { try core.deleteData(options: text); return true } } catch { failure = error }
        // Core owns the scope and the close decision, including closes before a failed deletion.
        await evictClosed()
        if let failure { throw failure }
    }
    /// Ends and forgets the wrappers whose runtime Core closed, so a later open gets a new one.
    private func evictClosed() async {
        for (slot, agent) in agents where agent.closed { agents[slot] = nil; try? await agent.close() }
    }
    private func admit(_ open: @escaping @Sendable () async throws -> LegacyCrocheAgent) async throws -> LegacyCrocheAgent {
        guard closing == nil else { throw LegacyCrocheError("closed", "The project is closed.") }
        let previous = admission
        let task = Task { await previous?.value; return try await open() }
        admission = Task { _ = try? await task.value }
        return try await task.value
    }
    private func openAgent(_ id: String?, options: LegacyAgentOptions) async throws -> LegacyCrocheAgent {
        guard closing == nil else { throw LegacyCrocheError("closed", "The project is closed.") }
        let core = self.core, pals = self.pals, text = try projectText(options.json)
        await evictClosed()
        // Opens are serialized, so the staged table is this open's.
        let patched = options.config != nil
        if patched { pals.stage(id, options.handlers) }
        defer { if patched { pals.unstage() } }
        // Cached calls still go to Core, which checks admission and the patch's identity.
        let handle = try await Offload.run { try core.agentWithOptions(id: id, options: text) }
        return try await attach(handle, handlers: patched ? options.handlers : nil)
    }
    /// `handlers`: a patched open Core admitted, so its handlers replace that slot's (latest wins).
    private func attach(_ handle: CoreRuntime, handlers: [String: ToolHandler]? = nil) async throws -> LegacyCrocheAgent {
        guard closing == nil else { throw LegacyCrocheError("closed", "The project is closed.") }
        let slot = try handle.instance().map { try projectText(.array([.string(handle.agentId()), .string($0)])) } ?? handle.agentId()
        if let handlers { try pals.rebind(slot, handlers) }
        if let existing = agents[slot], !existing.closed { return existing }
        let runtime = try await AgentEngine.adopt(core: handle, host: pals.host(slot))
        let agent = LegacyCrocheAgent(core: handle, runtime: runtime, hub: await runtime.subscriptionHub!)
        if closing != nil { try await agent.close(); throw LegacyCrocheError("closed", "The project is closed.") }
        agents[slot] = agent
        return agent
    }
    func close() async throws {
        if let closing { return try await closing.value }
        let core = self.core, pals = self.pals
        let task = Task {
            _ = try await Offload.run { core.close(); return true }
            for agent in self.agents.values { try await agent.close() }
            pals.stop()
        }
        closing = task
        try await task.value
    }
}
private func projectText(_ value: JSON) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    do { return String(decoding: try encoder.encode(value), as: UTF8.self) }
    catch { throw LegacyCrocheError("invalid_configuration", "Configuration must be JSON serializable.") }
}

private final class ProjectObserverContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var core: CoreProject?
    private let user: String?
    init(user: String?) { self.user = user }
    func attach(_ core: CoreProject) { lock.withLock { self.core = core } }
    func usage(_ event: JSON) -> JSON {
        let core = lock.withLock { self.core }
        var value = event
        value["user"] = (core?.user() ?? user).map(JSON.string) ?? .null
        value["crocheUserId"] = core?.crocheUserId().map(JSON.string) ?? .null
        return value
    }
}
