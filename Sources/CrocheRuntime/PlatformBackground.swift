import Foundation
import CrocheFFI
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif
#if canImport(DeviceCheck) && os(iOS)
import DeviceCheck
#endif

// MARK: Background (APP-API: registerBackground, OS identifier ai.croche.background)

/// The OS's deferred work for the background wake: one request at a time.
protocol BackgroundRequests: Sendable {
    /// Replaces any earlier request with one at or after `earliest`. A refusal throws
    /// `CorePalError` with `capability_unsupported` (the app is not set up for it) or
    /// `host_unavailable` (the OS will not run it now); Core reports it and still delivers in the
    /// foreground and at the next open.
    func submit(earliest: Date) throws
    /// Nothing is pending: withdraw the request.
    func cancel()
}

#if canImport(BackgroundTasks) && os(iOS)
/// BGTaskScheduler. App setup: `ai.croche.background` in `BGTaskSchedulerPermittedIdentifiers`
/// (Info.plist) and the Background fetch mode.
struct AppRefreshRequests: BackgroundRequests {
    static let identifier = "ai.croche.background"
    func submit(earliest: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = earliest
        do { try BGTaskScheduler.shared.submit(request) }
        catch let error as BGTaskScheduler.Error where error.code == .notPermitted {
            throw CorePalError.Failure(code: "capability_unsupported",
                detail: "Add \(Self.identifier) to BGTaskSchedulerPermittedIdentifiers and enable Background fetch.")
        } catch {
            throw CorePalError.Failure(code: "host_unavailable", detail: "BGTaskScheduler refused the request: \(error)")
        }
    }
    func cancel() { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
}
#endif

/// The pending set Core hands `schedule` (`[{id, at}]`, `at` ISO UTC): a timer while the app
/// runs, and the OS request for after. The timer fires `onDue` at the earliest `at`, never
/// before it and once per time; with no `onDue` yet it arms nothing (the notes still come at the
/// next `deliverDue`). The OS request follows the earliest `at` and is withdrawn when nothing is
/// pending. A refused request fails `schedule`; the timer stays armed.
final class PlatformSchedule: @unchecked Sendable {
    private let requests: (any BackgroundRequests)?
    private let clock: @Sendable () -> Double
    private let lock = NSLock()
    private var target: Double?, fired: Double?, timer: DispatchWorkItem?, closed = false
    private var due: (@Sendable () -> Void)?

    init(requests: (any BackgroundRequests)?, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.requests = requests; self.clock = clock
    }

    /// What runs a due delivery in this process (the factory sets it to `deliverDue`).
    var onDue: (@Sendable () -> Void)? {
        get { lock.withLock { due } }
        set { lock.withLock { due = newValue }; arm() }
    }

    func apply(_ entries: String) throws {
        guard let list = try? JSON(entries).array else {
            throw CorePalError.Failure(code: "internal", detail: "Core's schedule entries are malformed.")
        }
        let times = try list.map { entry -> Double in
            guard let text = entry["at"].string, let at = Self.epochMs(text) else {
                throw CorePalError.Failure(code: "internal", detail: "Core's schedule entry has no valid at.")
            }
            return at
        }
        let earliest = times.min()
        lock.withLock { target = earliest }
        arm()
        guard let requests else { return }
        if let earliest { try requests.submit(earliest: Date(timeIntervalSince1970: earliest / 1000)) } else { requests.cancel() }
    }

    func close() { lock.withLock { closed = true; timer?.cancel(); timer = nil } }

    /// One timer at the target; a timer that ends early re-arms, and a target already fired
    /// never fires again.
    private func arm() {
        let now = clock()
        let work: DispatchWorkItem? = lock.withLock {
            timer?.cancel(); timer = nil
            guard !closed, due != nil, let target, !(fired.map { target <= $0 } ?? false) else { return nil }
            let item = DispatchWorkItem { [weak self] in self?.fire(target) }
            timer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(max(0, target - now).rounded(.up))), execute: item)
            return item
        }
        _ = work
    }

    private func fire(_ at: Double) {
        if clock() < at { arm(); return }
        let run: (@Sendable () -> Void)? = lock.withLock {
            guard !closed, target == at, !(fired.map { at <= $0 } ?? false) else { return nil }
            fired = at; timer = nil
            return due
        }
        run?()
    }

    static func epochMs(_ text: String) -> Double? {
        let parse = ISO8601DateFormatter()
        parse.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parse.date(from: text) { return date.timeIntervalSince1970 * 1000 }
        parse.formatOptions = [.withInternetDateTime]
        return parse.date(from: text).map { $0.timeIntervalSince1970 * 1000 }
    }
}

/// One OS launch of the background task. `deliver` runs once (Core's `deliverDue`); the OS's
/// expiration cancels THIS launch's delivery only, including one that has not begun, and a
/// launch that already finished owns nothing to cancel. `done(true)` = it finished delivering.
final class BackgroundLaunch: @unchecked Sendable {
    private let deliver: @Sendable () async -> Bool
    private let lock = NSLock()
    private var task: Task<Void, Never>?, expired = false
    init(deliver: @escaping @Sendable () async -> Bool) { self.deliver = deliver }

    func start(_ done: @escaping @Sendable (Bool) -> Void) {
        let deliver = self.deliver
        let task = Task {
            let finished = await deliver()
            done(finished && !Task.isCancelled)
        }
        if lock.withLock({ self.task = task; return expired }) { task.cancel() }
    }
    func expire() { lock.withLock { expired = true; return task }?.cancel() }
}

/// One OS launch as the handler sees it: the OS's expiration, and the completion it waits for.
protocol BackgroundLaunchTask: AnyObject, Sendable {
    func onExpire(_ body: @escaping @Sendable () -> Void)
    func complete(success: Bool)
}

/// The OS's launch handlers for the background wake.
protocol BackgroundLaunches: Sendable {
    /// Installs `handler` for every launch of `identifier`; false = the OS refused it.
    func register(_ identifier: String, _ handler: @escaping @Sendable (any BackgroundLaunchTask) -> Void) -> Bool
}

#if canImport(BackgroundTasks) && os(iOS)
/// BGTaskScheduler. It refuses (false) an identifier missing from
/// `BGTaskSchedulerPermittedIdentifiers`; registering after launch finishes is an app bug the OS
/// traps, so `Croche.registerBackground` runs before `application(_:didFinishLaunchingWithOptions:)` returns.
struct AppRefreshLaunches: BackgroundLaunches {
    func register(_ identifier: String, _ handler: @escaping @Sendable (any BackgroundLaunchTask) -> Void) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { handler(OSLaunchTask($0)) }
    }
}
private final class OSLaunchTask: BackgroundLaunchTask, @unchecked Sendable {
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    func onExpire(_ body: @escaping @Sendable () -> Void) { task.expirationHandler = body }
    func complete(success: Bool) { task.setTaskCompleted(success: success) }
}
#endif

/// Core's `register_background`: install the launch handler for Core's identifier, then submit
/// the first request (Core's `schedule` moves it later). Each launch runs Core's wake once; the
/// OS's expiration cancels it. Any refusal is `host_unavailable` (Keel 22:08Z), never a silent Ok;
/// a platform with no OS launch is `capability_unsupported`. The OS keeps the first handler for
/// the process, so a later registration only replaces the wake it runs.
final class PlatformRegistration: @unchecked Sendable {
    private let launches: (any BackgroundLaunches)?
    private let requests: (any BackgroundRequests)?
    private let lock = NSLock()
    private var installed: Set<String> = [], wakes: [String: CoreBackgroundWake] = [:]

    init(launches: (any BackgroundLaunches)?, requests: (any BackgroundRequests)?) {
        self.launches = launches; self.requests = requests
    }

    func register(_ identifier: String, _ wake: CoreBackgroundWake) throws {
        guard let launches else {
            throw CorePalError.Failure(code: "capability_unsupported", detail: "This platform has no OS background launch.")
        }
        let install = lock.withLock { () -> Bool in
            wakes[identifier] = wake
            return !installed.contains(identifier)
        }
        if install {
            // The OS keeps the handler for the process, so it keeps this registration too.
            guard launches.register(identifier, { task in self.launch(identifier, task) }) else {
                lock.withLock { _ = wakes.removeValue(forKey: identifier) }
                throw CorePalError.Failure(code: "host_unavailable",
                    detail: "The OS refused the launch handler for \(identifier): list it in BGTaskSchedulerPermittedIdentifiers and register before launch finishes.")
            }
            lock.withLock { _ = installed.insert(identifier) }
        }
        do { try requests?.submit(earliest: Date()) } catch let CorePalError.Failure(_, detail) {
            throw CorePalError.Failure(code: "host_unavailable", detail: detail)
        } catch {
            throw CorePalError.Failure(code: "host_unavailable", detail: "The OS refused the request: \(error)")
        }
    }

    private func launch(_ identifier: String, _ task: any BackgroundLaunchTask) {
        guard let wake = lock.withLock({ wakes[identifier] }) else { task.complete(success: false); return }
        let cancel = CancelToken()
        let launch = BackgroundLaunch {
            if Task.isCancelled { return false }
            return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async { done.resume(returning: (try? wake.run(deadlineMs: nil, cancel: cancel)) != nil) }
            }
        }
        task.onExpire { cancel.cancel(); launch.expire() }
        launch.start { task.complete(success: $0) }
    }
}

// MARK: Attestation (ARCHITECTURE §2: a PAL effect)

/// The platform's attestation of this app binary, bound to `clientDataHash`.
protocol PlatformAttestor: Sendable {
    /// What Core declares: "ios-app-attest".
    var platform: String { get }
    func attest(clientData: String, clientDataHash: Data) async throws -> (token: String, keyId: String?)
}

#if canImport(DeviceCheck) && os(iOS)
/// Apple App Attest: a fresh key per registration, attested against Cloud's challenge.
/// Simulators cannot attest (`attestation_unsupported`).
struct AppAttest: PlatformAttestor {
    let platform = "ios-app-attest"
    static var supported: Bool { DCAppAttestService.shared.isSupported }
    func attest(clientData: String, clientDataHash: Data) async throws -> (token: String, keyId: String?) {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw CorePalError.Failure(code: "attestation_unsupported", detail: "App Attest is not available here (simulators cannot attest).")
        }
        do {
            let keyId = try await service.generateKey()
            let object = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            return (object.base64EncodedString(), keyId)
        } catch {
            throw CorePalError.Failure(code: "attestation_failed", detail: "App Attest failed: \(error)")
        }
    }
}
#endif

enum PlatformAttestation {
    /// Core's attest effect (`{clientData, clientDataHash, platform}`) through `attestor`, bounded
    /// by `timeoutMs`. No attestor: `attestation_unavailable`.
    static func run(_ attestor: (any PlatformAttestor)?, request: String, timeoutMs: UInt64) throws -> String {
        guard let attestor else {
            throw CorePalError.Failure(code: "attestation_unavailable", detail: "This host cannot attest.")
        }
        let call = try? JSON(request)
        // A malformed call is Core's bug, not an attestation fact.
        guard let clientData = call?["clientData"].string, let hash = base64URLDecode(call?["clientDataHash"].string ?? "") else {
            throw CorePalError.Failure(code: "internal", detail: "Core's attest effect is malformed.")
        }
        let box = AttestBox(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { box.set(.success(try await attestor.attest(clientData: clientData, clientDataHash: hash))) }
            catch { box.set(.failure(error)) }
            done.signal()
        }
        guard done.wait(timeout: .now() + .milliseconds(Int(min(timeoutMs, UInt64(Int.max))))) == .success else {
            task.cancel()
            throw CorePalError.Failure(code: "attestation_timeout", detail: "The attestor did not answer in \(timeoutMs) ms.")
        }
        let proof: (token: String, keyId: String?)
        do { proof = try box.get() } catch { throw effectFailure(error) }
        let reply: JSON = .object(["platform": .string(attestor.platform), "token": .string(proof.token),
                                   "keyId": proof.keyId.map(JSON.string) ?? .null])
        return String(decoding: try reply.encoded(), as: UTF8.self)
    }
}

private final class AttestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<(token: String, keyId: String?), Error>?
    func set(_ result: Result<(token: String, keyId: String?), Error>) { lock.withLock { value = result } }
    func get() throws -> (token: String, keyId: String?) { try lock.withLock { value! }.get() }
}
