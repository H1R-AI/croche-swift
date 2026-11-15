#if CROCHE_TEST_HOOKS
import Foundation
import CrocheFFI

// TEST-HOOKS BUILDS ONLY (CROCHE_SWIFT_TEST_HOOKS=1, Atlas's shared recipe): the private
// `openForTests` entry with a fixture Cloud origin. Never compiled into a release; the release
// bindings have no `openForTests`.

/// While a test sets `serve`, `Croche.open` opens through `openForTests` with the fixture origin,
/// and every HTTP effect is answered in-process by `serve`. No request leaves the process.
enum FixtureCloud {
    /// The origin Core is given. Nothing listens there: the host answers in-process.
    static let origin = "http://127.0.0.1:9"
    /// Hosts the fixture may name besides the origin (its registration's gateway).
    static let gatewayHosts: Set<String> = ["gateway.example"]
    nonisolated(unsafe) static var serve: RuntimeHTTP?
    /// Image bytes by URL, served to a pinned fetch where the platform dials pins (macOS).
    nonisolated(unsafe) static var images: [String: Data] = [:]
    /// `(url, connectTo)` of every image fetch served, so a test can assert the pin.
    nonisolated(unsafe) static var pinned: [(url: String, pin: String?)] = []
    /// URLs refused because they were outside the fixture: a test asserts this stays empty.
    nonisolated(unsafe) static var refused: [String] = []
    static let lock = NSLock()
}

/// The platform PAL with HTTP and DNS answered by the fixture; everything else is the real PAL.
final class FixtureHost: HostPal, @unchecked Sendable {
    let base: PlatformPal
    private let serve: RuntimeHTTP
    init(base: PlatformPal, serve: @escaping RuntimeHTTP) { self.base = base; self.serve = serve }

    func http(request: PalHttpRequest, sink: HttpSink, cancel: CancelToken) throws {
        // The platform's own pin rule first (iOS: a named pin is capability_unsupported).
        if request.connectTo != nil && !PlatformHTTP.dialsNamedPins { try effect { try PlatformHTTP.check(request) } }
        if let image = FixtureCloud.lock.withLock({ FixtureCloud.images[request.url] }) {
            FixtureCloud.lock.withLock { FixtureCloud.pinned.append((request.url, request.connectTo)) }
            sink.head(status: 200, headers: [PalHeader(name: "content-type", value: "image/png")])
            _ = sink.chunk(bytes: image)
            return
        }
        let host = URL(string: request.url)?.host ?? ""
        guard request.url.hasPrefix(FixtureCloud.origin + "/") || FixtureCloud.gatewayHosts.contains(host) else {
            FixtureCloud.lock.withLock { FixtureCloud.refused.append(request.url) }
            throw CorePalError.Failure(code: "host_unavailable", detail: "Outside the fixture: \(request.url)")
        }
        let serve = self.serve
        try effect {
            _ = try blockOn(milliseconds: Double(request.timeoutMs), cancel: cancel) { signal -> Bool in
                try await SwiftHost.adapt(serve, request, sink, signal); return true
            }
        }
    }
    /// A fixed public answer: no DNS query leaves the process.
    func resolve(host: String, cancel: CancelToken) throws -> [String] { ["93.184.216.34"] }

    func streamPlatform() -> HostStreamPlatform { base.streamPlatform() }
    func imageCodecAvailable() -> Bool { base.imageCodecAvailable() }
    func readImage(request: PalImageReadRequest, cancel: CancelToken) throws -> Data { try base.readImage(request: request, cancel: cancel) }
    func prepareImage(source: PalImageBytes, plan: PalImagePreparePlan, cancel: CancelToken) throws -> PalImageBytes { try base.prepareImage(source: source, plan: plan, cancel: cancel) }
    func releaseImage(capture: String) { base.releaseImage(capture: capture) }
    func decodeImage(bytes: Data, options: PalImageDecodeOptions, cancel: CancelToken) throws -> PalDecodedImage { try base.decodeImage(bytes: bytes, options: options, cancel: cancel) }
    func renderImage(request: PalImageRenderRequest, cancel: CancelToken) throws -> Data { try base.renderImage(request: request, cancel: cancel) }
    func releaseDecodedImage(handle: String) { base.releaseDecodedImage(handle: handle) }
    func platformFacts() -> PalPlatformFacts { base.platformFacts() }
    func readAsset(path: String) throws -> Data? { try base.readAsset(path: path) }
    func list(prefix: String) throws -> [String] { try base.list(prefix: prefix) }
    func read(key: String) throws -> String? { try base.read(key: key) }
    func write(key: String, value: String) throws { try base.write(key: key, value: value) }
    func readSecret(key: String) throws -> String? { try base.readSecret(key: key) }
    func writeSecret(key: String, value: String) throws { try base.writeSecret(key: key, value: value) }
    func remove(key: String) throws { try base.remove(key: key) }
    func removeSecret(key: String) throws { try base.removeSecret(key: key) }
    func lock(key: String) throws -> PalLockOutcome { try base.lock(key: key) }
    func unlock(key: String) throws { try base.unlock(key: key) }
    func storeIdentity() -> String { base.storeIdentity() }
    func tool(invocation: String, cancel: CancelToken) throws -> ToolOutput { try base.tool(invocation: invocation, cancel: cancel) }
    func attest(request: String, timeoutMs: UInt64) throws -> String { try base.attest(request: request, timeoutMs: timeoutMs) }
    func nowMs() -> Double { base.nowMs() }
    func utcOffsetMinutes(atMs: Double) -> Int64 { base.utcOffsetMinutes(atMs: atMs) }
    func random() -> String { base.random() }
    func wake(atMs: Double?) { base.wake(atMs: atMs) }
    func schedule(entries: String) throws { try base.schedule(entries: entries) }
    func registerBackground(identifier: String, wake: CoreBackgroundWake) throws { try base.registerBackground(identifier: identifier, wake: wake) }
    func archiveAppendLine(entry: String, line: String) throws { try base.archiveAppendLine(entry: entry, line: line) }
    func archiveReadLines(entry: String) throws -> [String] { try base.archiveReadLines(entry: entry) }
    func archiveReplaceLines(entry: String, lines: [String]) throws { try base.archiveReplaceLines(entry: entry, lines: lines) }
    func archiveRemove(entry: String) throws { try base.archiveRemove(entry: entry) }
    func archiveEntries(prefix: String) throws -> [ArchiveEntry] { try base.archiveEntries(prefix: prefix) }
    func storageCapability() -> StorageCapability { base.storageCapability() }
}

extension Croche {
    /// `open` through the private test entry, when a test has set `FixtureCloud.serve`.
    static func fixtureOpen(_ open: String, _ registrations: [CoreToolRegistration], _ storage: (any StoragePal)?,
                            _ recoveryJson: String?, _ serve: @escaping RuntimeHTTP) async throws -> Croche {
        let base = try platformHost(), host = FixtureHost(base: base, serve: serve)
        let store = storageArgument(storage, base)
        return Croche(core: try await owner({ try CoreCroche.openForTests(openJson: open, registrations: registrations,
                                                                           storage: store, host: host, bindingFactsJson: BindingFacts.json(),
                                                                           intervalsJson: fixtureSettings, recoveryJson: recoveryJson) },
                                            discard: { try? $0.shutdown() }))
    }

    private static let fixtureSettings = #"{"cloudOrigin":"\#(FixtureCloud.origin)"}"#
}
#endif
