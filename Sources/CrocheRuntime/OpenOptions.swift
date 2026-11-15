import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum DebugVisibility: String, Sendable { case runtime }
enum Attestation: String, Sendable { case platform, off }
// Q9 recommendation: backgroundDelivery is deferred until the per-agent identifier rule.
struct LegacyOpenOptions: Sendable {
    var cloudUrl: String?
    var projectKey: String
    /// The app's bundled project configuration (a ProjectConfig or its release export); Core selects
    /// it or a newer released config. `temperature`: number 0...2, absent uses a tuned default, `.null` = omit.
    /// Structured calls always omit it. Remote temperature configs require schema 6 / 0.6+.
    var bundledConfig: JSON
    var user: String?
    var handlers: [String: ToolHandler]
    var language: String?
    var timeZone: String?
    var streaming: Bool?
    var backgroundSync: Bool?
    var maintenanceIntervalMs: Double?
    var debugKey: String?
    var requestTimeoutMs: Double?
    var maxPendingEvents: Int?
    var syncIntervalMs: Double?
    var maintenanceBackoffMs: Double?
    var retentionBytes: Int?
    var onUsage: (@Sendable (ProjectUsageEvent) -> Void)?
    var onDebugEvent: (@Sendable (RuntimeDebugEvent) -> Void)?
    var debugVisibility: DebugVisibility?
    var attestation: Attestation?
    var projectDirectory: URL?
    var http: RuntimeHTTP?
    init(cloudUrl: String? = nil,
                projectKey: String,
                bundledConfig: JSON,
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
        self.bundledConfig = bundledConfig
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
        do { _ = try hostJSON().encoded(); _ = try bundledConfig.encoded() }
        catch { throw LegacyCrocheError("invalid_configuration", "Configuration must be JSON serializable.") }
        let records = try ProjectRecordFiles.forOpen(projectDirectory: projectDirectory)
        let directory = try NativeProjectFiles.directory(projectDirectory: projectDirectory)
        var identity = hostJSON(); identity["user"] = user.map(JSON.string) ?? .null
        let namespace = try storageIdentity(config: identity)["storageKey"].string ?? "croche.runtime"
        let zone: TimeZone?
        if let timeZone {
            guard let parsed = TimeZone(identifier: timeZone) else { throw LegacyCrocheError("invalid_configuration", "timeZone must name an IANA time zone") }
            zone = parsed
        } else { zone = nil }
        let attestor: (any RuntimeAttestor)?
        #if canImport(DeviceCheck) && os(iOS) && !targetEnvironment(simulator)
        attestor = attestation == .off ? nil : AppAttestAttestor()
        #else
        attestor = nil
        #endif
        let test = NativeProjectFiles.testing
        return NativeProjectOptions(host: hostJSON(), bundledConfig: bundledConfig, user: user,
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
        guard let projectDirectory else { throw LegacyCrocheError("storage_error", "This platform requires projectDirectory") }
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
