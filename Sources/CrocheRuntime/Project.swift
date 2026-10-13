import Foundation
import CrocheFFI

/// Code overrides and instance admission go unchanged to Core.
public struct AgentOptions: Sendable {
    public var instance: String?
    public var fresh: Bool?
    public var config: JSON?
    public init(instance: String? = nil, fresh: Bool? = nil, config: JSON? = nil) {
        self.instance = instance; self.fresh = fresh; self.config = config
    }
    var json: JSON {
        var value: [String: JSON] = [:]
        if let instance { value["instance"] = .string(instance) }
        if let fresh { value["fresh"] = .bool(fresh) }
        if let config { value["config"] = config }
        return .object(value)
    }
}

public typealias ProjectToolContext = ToolContext
public typealias ProjectUsageEvent = JSON
public typealias RuntimeDebugEvent = JSON
public typealias MemoryChangedEvent = JSON

/// The project-returned agent uses the existing Runtime's port, subscriptions and memory.
public final class CrocheAgent: Sendable {
    private let core: CoreRuntime
    private let runtime: CrocheRuntime
    private let lifetime = ProjectAgentLifetime()
    private let hub: StreamHub
    public let id: String
    public let instance: String?
    public let created: Bool
    public let logId: String
    init(core: CoreRuntime, runtime: CrocheRuntime, hub: StreamHub) {
        self.hub = hub
        self.core = core; self.runtime = runtime
        id = core.agentId(); instance = core.instance(); created = core.created(); logId = runtime.logId
    }
    public var name: String? { core.name() }
    public var mode: String? { core.mode() }
    public var visibleTools: [String]? { core.visibleTools() }
    public var closed: Bool { lifetime.closed }
    public var memory: CrocheMemory { runtime.memory }
    private func check() throws { if closed { throw CrocheError("closed", "The agent is closed.") } }
    public func setTools(_ visible: [String]?) async throws {
        try check(); let core = self.core
        _ = try await CrocheRuntime.offload { try core.setTools(visible: visible); return true }
    }
    public func setMode(_ mode: String?) async throws {
        try check(); let core = self.core
        _ = try await CrocheRuntime.offload { try core.setMode(mode: mode); return true }
    }
    public func sync() async throws { try check(); _ = try await runtime.sync() }
    public func send(_ input: SendInput, _ options: SendOptions = SendOptions()) async throws -> Receipt {
        try check(); return try await runtime.send(input, options: options)
    }
    public func request(_ input: SendInput, _ options: RequestOptions = RequestOptions()) async throws -> RequestResult {
        try check()
        let result = try await runtime.request(input, options: SendOptions(responseFormat: options.responseFormat), wait: options.wait)
        try? await runtime.refreshMemory()
        return result
    }
    public func subscribe(_ options: SubscribeOptions) -> AgentSubscription { hub.subscribe(options) }
    public func history(_ options: HistoryOptions) async throws {
        try check(); try await runtime.history(before: options.before, limit: options.limit)
    }
    public func cancel(_ id: String? = nil) async throws {
        try check()
        if let id { try await runtime.cancel(id) }
        else {
            let core = self.core
            _ = try await CrocheRuntime.offload { core.cancelTurn(); return true }
        }
    }
    public func clearHistory() async throws { try check(); try await runtime.clearHistory(); try? await runtime.refreshMemory() }
    public func close() async throws {
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
    var config: JSON
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
    let options: NativeProjectOptions
    init(_ options: NativeProjectOptions) { self.options = options }
    func pal(agent: String) -> any HostPal {
        let options = self.options
        let slot = NativeProjectSlot.storageLabel(agent)
        let handlers = options.handlers.mapValues { handler -> ToolHandler in
            { invocation, context in
                var data = context.data.object ?? [:]
                let issued = data.removeValue(forKey: "userId")?.string
                data["user"] = options.user.map(JSON.string) ?? .null
                data["crocheUserId"] = issued.flatMap { $0.isEmpty ? nil : $0 }.map(JSON.string) ?? .null
                do { return try await handler(invocation, ToolContext(data: .object(data), cancellation: context.cancellation, images: context.images)) }
                catch { throw CrocheError("effect_failed", "The tool handler failed.") }
            }
        }
        // A fresh host for every request: record and default-agent PALs are separate.
        let host = SwiftHost(storage: options.storage(slot), secrets: options.secretStorage(slot),
            attestor: options.attestor, http: options.fetch, tools: handlers,
            background: options.backgroundSync, projectRecords: options.records())
        host.timeZone = options.timeZone
        lock.withLock { if !NativeProjectSlot.isMaintenance(agent) { hosts[agent] = host }; all.append(host) }
        return host
    }
    func host(_ slot: String) throws -> SwiftHost {
        try lock.withLock {
            guard let host = hosts[slot] else { throw CrocheError("core_error", "Core opened an agent without requesting its host.") }
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
public final class Croche: Sendable {
    private let core: CoreProject
    private let pals: NativeProjectPals
    private let session: NativeProjectSession
    private init(core: CoreProject, pals: NativeProjectPals) {
        self.core = core; self.pals = pals; session = NativeProjectSession(core: core, pals: pals)
    }
    public var user: String? { core.user() }
    public var installationId: String? { core.installationId() }
    public var crocheUserId: String? { core.crocheUserId() }
    public var agentIds: [String] { core.agentIds() }
    var applied: JSON { (try? JSON(core.applied())) ?? .null }
    public static func open(_ options: OpenOptions) async throws -> Croche {
        let native = try await CrocheRuntime.offload { try options.native() }
        return try await open(native)
    }
    public static func deleteStore(_ options: OpenOptions, agent: String? = nil) async throws {
        let native = try await CrocheRuntime.offload { try options.native() }
        try await deleteStore(native, agent: agent)
    }
    static func open(_ options: NativeProjectOptions) async throws -> Croche {
        CrocheRuntime.warnIfReleaseBuildCarriesDebugKey(options.host)
        let pals = NativeProjectPals(options)
        let context = ProjectObserverContext(user: options.user)
        var host = options.host
        if let attestor = options.attestor { host["attestationPlatform"] = .string(attestor.platform) }
        let wire = ProjectOpenOptions(host: try projectText(host), user: options.user,
            config: try projectText(options.config), handlers: Array(options.handlers.keys), language: options.language,
            streaming: options.streaming, backgroundSync: options.backgroundSync,
            maintenanceIntervalMs: options.maintenanceIntervalMs)
        do {
            let core = try await CrocheRuntime.offload {
                try CoreProject.open(pals: pals, options: wire, onUsage: options.onUsage.map { listener in EventHook { listener(context.usage($0)) } },
                                     onDebug: options.onDebugEvent.map(EventHook.init))
            }
            context.attach(core)
            return Croche(core: core, pals: pals)
        } catch { pals.stop(); throw error }
    }
    static func deleteStore(_ options: NativeProjectOptions, agent: String? = nil) async throws {
        let pals = NativeProjectPals(options); defer { pals.stop() }
        let host = try projectText(options.host), config = try projectText(options.config)
        _ = try await CrocheRuntime.offload {
            try ffiProjectDelete(pals: pals, host: host, user: options.user, config: config, agent: agent); return true
        }
    }
    public func agent(_ id: String? = nil, _ options: AgentOptions = AgentOptions()) async throws -> CrocheAgent {
        try await session.agent(id, options)
    }
    public func close() async throws { try await session.close() }
}

private actor NativeProjectSession {
    private let core: CoreProject
    private let pals: NativeProjectPals
    private var agents: [String: CrocheAgent] = [:]
    private var closing: Task<Void, Error>?
    private var admission: Task<Void, Never>?
    init(core: CoreProject, pals: NativeProjectPals) { self.core = core; self.pals = pals }
    public func agent(_ id: String? = nil, _ options: AgentOptions = AgentOptions()) async throws -> CrocheAgent {
        guard closing == nil else { throw CrocheError("closed", "The project is closed.") }
        let previous = admission
        let task = Task { await previous?.value; return try await self.openAgent(id, options: options) }
        admission = Task { _ = try? await task.value }
        return try await task.value
    }
    private func openAgent(_ id: String?, options: AgentOptions) async throws -> CrocheAgent {
        guard closing == nil else { throw CrocheError("closed", "The project is closed.") }
        let core = self.core, text = try projectText(options.json)
        // Cached calls still go to Core, which checks overrides and admission.
        let handle = try await CrocheRuntime.offload { try core.agentWithOptions(id: id, options: text) }
        guard closing == nil else { throw CrocheError("closed", "The project is closed.") }
        let slot = try handle.instance().map { try projectText(.array([.string(handle.agentId()), .string($0)])) } ?? handle.agentId()
        if let existing = agents[slot], !existing.closed { return existing }
        let runtime = try await CrocheRuntime.adopt(core: handle, host: pals.host(slot))
        let agent = CrocheAgent(core: handle, runtime: runtime, hub: await runtime.subscriptionHub!)
        if closing != nil { try await agent.close(); throw CrocheError("closed", "The project is closed.") }
        agents[slot] = agent
        return agent
    }
    public func close() async throws {
        if let closing { return try await closing.value }
        let core = self.core, pals = self.pals
        let task = Task {
            _ = try await CrocheRuntime.offload { core.close(); return true }
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
    catch { throw CrocheError("invalid_configuration", "Configuration must be JSON serializable.") }
}
private func ffiProjectDelete(pals: any HostPalFactory, host: String, user: String?, config: String, agent: String?) throws {
    try deleteStore(pals: pals, host: host, user: user, config: config, agent: agent)
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
