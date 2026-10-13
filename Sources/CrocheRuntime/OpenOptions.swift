import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum DebugVisibility: String, Sendable { case runtime }
public enum Attestation: String, Sendable { case platform, off }
// Q9 recommendation: backgroundDelivery is deferred until the per-agent identifier rule.
public struct OpenOptions: Sendable {
    public var cloudUrl: String?
    public var projectKey: String
    public var config: JSON
    public var user: String?
    public var handlers: [String: ToolHandler]
    public var language: String?
    public var timeZone: String?
    public var streaming: Bool?
    public var backgroundSync: Bool?
    public var maintenanceIntervalMs: Double?
    public var debugKey: String?
    public var requestTimeoutMs: Double?
    public var maxPendingEvents: Int?
    public var syncIntervalMs: Double?
    public var maintenanceBackoffMs: Double?
    public var retentionBytes: Int?
    public var onUsage: (@Sendable (ProjectUsageEvent) -> Void)?
    public var onDebugEvent: (@Sendable (RuntimeDebugEvent) -> Void)?
    public var debugVisibility: DebugVisibility?
    public var attestation: Attestation?
    public var projectDirectory: URL?
    public var http: RuntimeHTTP?
    public init(cloudUrl: String? = nil,
                projectKey: String,
                config: JSON,
                user: String? = nil,
                handlers: [String: ToolHandler] = [:],
                language: String? = nil,
                timeZone: String? = nil,
                streaming: Bool? = nil,
                backgroundSync: Bool? = nil,
                maintenanceIntervalMs: Double? = nil,
                debugKey: String? = nil,
                requestTimeoutMs: Double? = nil,
                maxPendingEvents: Int? = nil,
                syncIntervalMs: Double? = nil,
                maintenanceBackoffMs: Double? = nil,
                retentionBytes: Int? = nil,
                onUsage: (@Sendable (ProjectUsageEvent) -> Void)? = nil,
                onDebugEvent: (@Sendable (RuntimeDebugEvent) -> Void)? = nil,
                debugVisibility: DebugVisibility? = nil,
                attestation: Attestation? = nil,
                projectDirectory: URL? = nil,
                http: RuntimeHTTP? = nil) {
        self.cloudUrl = cloudUrl
        self.projectKey = projectKey
        self.config = config
        self.user = user
        self.handlers = handlers
        self.language = language
        self.timeZone = timeZone
        self.streaming = streaming
        self.backgroundSync = backgroundSync
        self.maintenanceIntervalMs = maintenanceIntervalMs
        self.debugKey = debugKey
        self.requestTimeoutMs = requestTimeoutMs
        self.maxPendingEvents = maxPendingEvents
        self.syncIntervalMs = syncIntervalMs
        self.maintenanceBackoffMs = maintenanceBackoffMs
        self.retentionBytes = retentionBytes
        self.onUsage = onUsage
        self.onDebugEvent = onDebugEvent
        self.debugVisibility = debugVisibility
        self.attestation = attestation
        self.projectDirectory = projectDirectory
        self.http = http
    }
    func hostJSON() -> JSON {
        var host: JSON = .object(["projectKey": .string(projectKey)])
        if let cloudUrl { host["cloudUrl"] = .string(cloudUrl) }
        if let debugKey { host["debugKey"] = .string(debugKey) }
        if let debugVisibility { host["debugVisibility"] = .string(debugVisibility.rawValue) }
        if let requestTimeoutMs { host["requestTimeoutMs"] = .number(requestTimeoutMs) }
        if let maxPendingEvents { host["maxPendingEvents"] = .number(Double(maxPendingEvents)) }
        if let syncIntervalMs { host["syncIntervalMs"] = .number(syncIntervalMs) }
        if let maintenanceBackoffMs { host["maintenanceBackoffMs"] = .number(maintenanceBackoffMs) }
        if let retentionBytes { host["retentionBytes"] = .number(Double(retentionBytes)) }
        return host
    }
    func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        language ?? preferredLanguages.first
    }
    func native() throws -> NativeProjectOptions {
        do { _ = try hostJSON().encoded(); _ = try config.encoded() }
        catch { throw CrocheError("invalid_configuration", "Configuration must be JSON serializable.") }
        let records = try ProjectRecordFiles.forOpen(projectDirectory: projectDirectory)
        let directory = try NativeProjectFiles.directory(projectDirectory: projectDirectory)
        var identity = hostJSON(); identity["user"] = user.map(JSON.string) ?? .null
        let namespace = try CrocheRuntime.identity(config: identity)["storageKey"].string ?? "croche.runtime"
        let zone: TimeZone?
        if let timeZone {
            guard let parsed = TimeZone(identifier: timeZone) else { throw CrocheError("invalid_configuration", "timeZone must name an IANA time zone") }
            zone = parsed
        } else { zone = nil }
        let attestor: (any RuntimeAttestor)?
        #if canImport(DeviceCheck) && os(iOS) && !targetEnvironment(simulator)
        attestor = attestation == .off ? nil : AppAttestAttestor()
        #else
        attestor = nil
        #endif
        let test = NativeProjectFiles.testing
        return NativeProjectOptions(host: hostJSON(), config: config, user: user,
            language: resolvedLanguage(), handlers: handlers, streaming: streaming ?? true,
            backgroundSync: backgroundSync ?? true, maintenanceIntervalMs: maintenanceIntervalMs ?? 60_000,
            storage: { slot in FileRuntimeStorage(url: NativeProjectFiles.file(directory: directory, namespace: namespace, slot: slot)) },
            secretStorage: { slot in
                let key = NativeProjectFiles.key(namespace: namespace, slot: slot)
                if let test { return FileRuntimeSecretStore(url: test.appendingPathComponent(key + ".secrets")) }
                #if canImport(Security) && !os(Linux)
                return KeychainSecretStore(account: key)
                #else
                return FileRuntimeSecretStore(url: directory.appendingPathComponent(key + ".secrets"))
                #endif
            }, attestor: attestor, fetch: http, timeZone: zone,
            records: { test.map { dir in ProjectRecordFiles(directory: { dir }) } ?? records },
            onUsage: onUsage, onDebugEvent: onDebugEvent)
    }
}

// Test-only redirection keeps host gates inside their own worktree, out of Keychain/private app storage.
enum NativeProjectFiles {
    nonisolated(unsafe) static var testing: URL?
    static func directory(projectDirectory: URL?) throws -> URL {
        if let testing { return testing }
        #if os(Linux)
        guard let projectDirectory else { throw CrocheError("storage_error", "This platform requires projectDirectory") }
        return projectDirectory
        #else
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = base.appendingPathComponent("croche", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var excluded = url, values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return url
        #endif
    }
    static func file(directory: URL, namespace: String, slot: String) -> URL {
        directory.appendingPathComponent(key(namespace: namespace, slot: slot) + ".json")
    }
    static func key(namespace: String, slot: String) -> String {
        namespace + ".agent." + slotHash(slot)
    }
    static func slotHash(_ slot: String) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: Data(slot.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        PortableSHA256.hex(Array(slot.utf8))
        #endif
    }
}

// Core's maintenance label selects the instance's physical store, never its live handle.
enum NativeProjectSlot {
    static func isMaintenance(_ label: String) -> Bool {
        (try? JSON(label).array?.first?.string) == "$gc"
    }
    static func storageLabel(_ label: String) -> String {
        guard let parts = try? JSON(label).array, parts.count == 3,
              parts[0].string == "$gc", parts[1].string != nil, parts[2].string != nil else { return label }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(JSON.array(Array(parts.dropFirst()))), as: UTF8.self)
    }
}
