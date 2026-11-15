import Foundation
import CrocheFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The 0.6 iOS platform PAL (ARCHITECTURE §2a, Vale's #820 seam): keyed storage with Keychain
/// secrets, app assets, resolver facts and HTTP. Core owns names, policy and every deadline.
/// The legacy hooks Core still declares during its keyed cutover (tool, archive, wake) are
/// refused or inert here: tools reach Core through `CoreToolDefinition`, and the cutover deletes them.
final class PlatformPal: HostPal, @unchecked Sendable {
    private let storage: PlatformStorage
    let secrets: any PlatformSecrets
    private let directory: URL
    private let bundle: Bundle
    let session = RuntimeSession()
    let images = NativeImagePal()
    /// Where this host runs (a fact Core reads); a React Native host sets `.reactNative`.
    var streamPlatformFact = HostStreamPlatform.other

    /// The background wake's timer and OS request (APP-API: registerBackground).
    let schedules: PlatformSchedule
    /// The OS launch handler Core installs once (APP-API: registerBackground).
    let registration: PlatformRegistration
    /// App Attest where this device can attest; nil elsewhere (Core then reports `attestation_unavailable`).
    let attestor: (any PlatformAttestor)?
    /// What the factory declares to Core as the attestation platform: nil = this host cannot attest.
    var attestationPlatform: String? { attestor?.platform }
    /// The device's preferred languages, read at each `platformFacts` (the app may change them).
    let preferredLanguages: @Sendable () -> [String]

    init(directory: URL, secrets: (any PlatformSecrets)? = nil, bundle: Bundle = .main,
         backgroundRequests: (any BackgroundRequests)? = PlatformPal.osBackgroundRequests(),
         backgroundLaunches: (any BackgroundLaunches)? = PlatformPal.osBackgroundLaunches(),
         attestor: (any PlatformAttestor)? = PlatformPal.osAttestor(),
         preferredLanguages: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }) {
        self.preferredLanguages = preferredLanguages
        let storage = PlatformStorage(directory: directory)
        self.storage = storage; self.directory = directory; self.bundle = bundle
        self.schedules = PlatformSchedule(requests: backgroundRequests); self.attestor = attestor
        self.registration = PlatformRegistration(launches: backgroundLaunches, requests: backgroundRequests)
        #if canImport(Security) && !os(Linux)
        self.secrets = secrets ?? KeychainSecrets()
        #else
        self.secrets = secrets ?? FileSecrets(storage: storage)
        #endif
    }

    static func osBackgroundRequests() -> (any BackgroundRequests)? {
        #if canImport(BackgroundTasks) && os(iOS)
        return AppRefreshRequests()
        #else
        return nil
        #endif
    }
    static func osBackgroundLaunches() -> (any BackgroundLaunches)? {
        #if canImport(BackgroundTasks) && os(iOS)
        return AppRefreshLaunches()
        #else
        return nil
        #endif
    }
    static func osAttestor() -> (any PlatformAttestor)? {
        #if canImport(DeviceCheck) && os(iOS)
        return AppAttest.supported ? AppAttest() : nil
        #else
        return nil
        #endif
    }

    /// The platform default store: Application Support/croche, excluded from backup.
    static func standard() throws -> PlatformPal {
        let directory = try NativeProjectFiles.directory(projectDirectory: nil)
        return PlatformPal(directory: directory, secrets: testingSecrets(directory))
    }
    /// Tests keep secrets in files, out of the developer's Keychain (Keel, #861 6537337677).
    static func testingSecrets(_ directory: URL) -> (any PlatformSecrets)? {
        NativeProjectFiles.testing.map { _ in FileSecrets(storage: PlatformStorage(directory: directory)) }
    }

    private func host<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw LegacyCrocheError(error).ffi }
    }

    // MARK: Storage
    func read(key: String) throws -> String? { try host { try storage.read("state", key) } }
    func write(key: String, value: String) throws { try host { try storage.write("state", key, value) } }
    func remove(key: String) throws { try host { try storage.remove("state", key) } }
    func list(prefix: String) throws -> [String] { try host { try storage.list("state", prefix) } }
    /// Contention is the fact `.held`, never an error (ARCHITECTURE §2a).
    @discardableResult func lock(key: String) throws -> PalLockOutcome { try host { try storage.lock(key) } }
    func unlock(key: String) { storage.unlock(key) }
    func readSecret(key: String) throws -> String? { try host { try secrets.read(key) } }
    func writeSecret(key: String, value: String) throws { try host { try secrets.write(key, value) } }
    func removeSecret(key: String) throws { try host { try secrets.remove(key) } }
    func storeIdentity() -> String { directory.standardizedFileURL.path }

    // MARK: Assets, resolver, facts
    func readAsset(path: String) throws -> Data? { try effect { try PlatformAssets.read(path, bundle: bundle) } }
    func resolve(host name: String, cancel: CancelToken) throws -> [String] { try effect { try PlatformResolver.resolve(name) } }
    /// `debuggable` and `targetKind` come from `AppBuildFacts`, never the SDK's own build macro
    /// (Keel's S2 ruling, pin 4).
    /// Facts only; Core applies them (Keel 23:55Z/00:27Z). `locale`: the device's first preferred
    /// language, which Core uses for an omitted `language`. `attestationPlatform`: set only when this
    /// host has an attestor. `browserFetch`: never (a native host is not a browser).
    func platformFacts() -> PalPlatformFacts {
        PalPlatformFacts(targetKind: AppBuildFacts.targetKind, debuggable: AppBuildFacts.debuggable, locale: preferredLanguages().first, attestationPlatform: attestationPlatform, browserFetch: nil)
    }

    // MARK: HTTP
    func http(request: PalHttpRequest, sink: HttpSink, cancel: CancelToken) throws {
        try effect {
            if try PlatformHTTP.direct(request, sink: sink, cancel: cancel) { return }
            let session = session
            _ = try blockOn(milliseconds: Double(request.timeoutMs), cancel: cancel) { signal -> Bool in
                try await session.stream(request, into: sink, cancellation: signal); return true
            }
        }
    }

    // MARK: Images
    func imageCodecAvailable() -> Bool { images.codecAvailable }
    func readImage(request: PalImageReadRequest, cancel: CancelToken) throws -> Data {
        try effect { try images.read(request, cancel) }
    }
    func prepareImage(source: PalImageBytes, plan: PalImagePreparePlan, cancel: CancelToken) throws -> PalImageBytes {
        try effect { try images.prepare(source, plan, cancel) }
    }
    func releaseImage(capture: String) { images.release(capture) }
    func decodeImage(bytes: Data, options: PalImageDecodeOptions, cancel: CancelToken) throws -> PalDecodedImage {
        try effect { try images.decode(bytes, options, cancel) }
    }
    func renderImage(request: PalImageRenderRequest, cancel: CancelToken) throws -> Data {
        try effect { try images.render(request, cancel) }
    }
    func releaseDecodedImage(handle: String) { images.releaseDecoded(handle) }
    /// A fact about the host, never a batching choice. A React Native host reports .reactNative.
    func streamPlatform() -> HostStreamPlatform { streamPlatformFact }

    // MARK: Clock, randomness
    func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
    func utcOffsetMinutes(atMs: Double) -> Int64 {
        Int64(TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: atMs / 1000)) / 60)
    }
    func random() -> String { UUID().uuidString }

    // MARK: Attestation, background
    func attest(request: String, timeoutMs: UInt64) throws -> String {
        try PlatformAttestation.run(attestor, request: request, timeoutMs: timeoutMs)
    }
    /// The pending set changed or the store opened: the timer and the OS request follow it.
    func schedule(entries: String) throws { try schedules.apply(entries) }
    /// Core's OS install: the launch handler for `identifier`, then the first request.
    func registerBackground(identifier: String, wake: CoreBackgroundWake) throws {
        try registration.register(identifier, wake)
    }

    // MARK: Legacy hooks during Core's keyed cutover
    func tool(invocation: String, cancel: CancelToken) throws -> ToolOutput {
        throw FfiError.Failure(code: "tool_not_dispatched", message: "Tools reach Core through their definitions.")
    }
    func wake(atMs: Double?) {}
    func archiveAppendLine(entry: String, line: String) throws { throw Self.noArchive }
    func archiveReadLines(entry: String) throws -> [String] { throw Self.noArchive }
    func archiveReplaceLines(entry: String, lines: [String]) throws { throw Self.noArchive }
    func archiveRemove(entry: String) throws { throw Self.noArchive }
    func archiveEntries(prefix: String) throws -> [ArchiveEntry] { throw Self.noArchive }
    func storageCapability() -> StorageCapability { .keyed }
    private static let noArchive = FfiError.Failure(code: "archive_unavailable", message: "Core keeps the archive in keyed storage.")
}

/// App asset references, resolved unchanged (APP-API: iOS = a main-bundle resource or a
/// `file://` URL). Missing = nil (Core reports `invalid_wiki`); any other failure = asset_read_failed.
enum PlatformAssets {
    static func read(_ reference: String, bundle: Bundle) throws -> Data? {
        let file: URL
        if reference.hasPrefix("file://") {
            guard let url = URL(string: reference), url.isFileURL else { throw LegacyCrocheError("asset_read_failed", "The asset URL is malformed.") }
            file = url
        } else {
            guard let url = bundle.url(forResource: reference, withExtension: nil) else { return nil }
            file = url
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory) else { return nil }
        guard !directory.boolValue else { throw LegacyCrocheError("asset_read_failed", "The asset is a directory.") }
        do { return try Data(contentsOf: file) } catch { throw LegacyCrocheError("asset_read_failed", "The asset could not be read.") }
    }
}

/// Resolver facts only: every address the system resolver gives, unfiltered. Core owns policy.
enum PlatformResolver {
    static func resolve(_ name: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue) // Glibc imports __socket_type as an enum
        #else
        hints.ai_socktype = Int32(SOCK_STREAM)
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(name, nil, &hints, &list)
        guard status == 0, let first = list else { throw LegacyCrocheError("network_error", "The host name did not resolve.") }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer)
            if !addresses.contains(address) { addresses.append(address) }
        }
        return addresses
    }
}

/// URLSession cannot dial a pinned address while keeping the URL host's Host/SNI. It serves a pin
/// only where the pin holds trivially (the URL host is that IP literal); any other pin goes to the
/// direct client, and where there is none it is `capability_unsupported`, never an unpinned success.
enum PlatformHTTP {
    /// Whether this platform dials a pin that is not the URL's own IP literal. iOS does not in 0.6
    /// (APP-API:42, Keel 15:43Z): a hostname image or debugger URL is `capability_unsupported`
    /// there; IP literals and loopback are unchanged. macOS keeps the pinned dial. Linux has no
    /// direct client (it needs Network.framework), so it does not dial named pins either.
    #if os(iOS) || !canImport(Network)
    static let dialsNamedPins = false
    #else
    static let dialsNamedPins = true
    #endif

    /// A pinned request goes through the direct client (true = done); an unpinned one, or an
    /// IP-literal pin equal to the URL host, is URLSession's (false). Where the platform does not
    /// dial named pins, any other pin is `capability_unsupported` before a connection.
    static func direct(_ request: PalHttpRequest, sink: any HttpSinkProtocol, cancel: CancelToken,
                       dialsNamedPins: Bool = PlatformHTTP.dialsNamedPins) throws -> Bool {
        guard let pin = request.connectTo, (try? check(request)) == nil else { return false }
        if !dialsNamedPins { try check(request) }
        #if canImport(Network)
        try DirectHTTP().http(request, pin: pin, sink: sink, cancel: cancel)
        return true
        #else
        try check(request)
        return false
        #endif
    }
    static func check(_ request: PalHttpRequest) throws {
        guard let pin = request.connectTo else { return }
        guard let host = URLComponents(string: request.url)?.host, isIPLiteral(host), canonical(host) == canonical(pin) else {
            throw LegacyCrocheError("capability_unsupported", "This platform cannot pin a connection to a resolved address.")
        }
    }
    static func isIPLiteral(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
    }
    /// One spelling per address, so `[::1]` and `::1` (or `0:0::1`) compare equal.
    static func canonical(_ text: String) -> String {
        let bare = text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, bare, &v4) == 1, inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil { return String(cString: buffer) }
        if inet_pton(AF_INET6, bare, &v6) == 1, inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil { return String(cString: buffer) }
        return bare.lowercased()
    }
}
