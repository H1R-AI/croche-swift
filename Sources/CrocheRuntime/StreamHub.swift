import Foundation

// Proposed SDK-internal seam only. Core owns projection, ordered capture, delta fences,
// and storage. select/history never allocate a second canonical observation.
struct StreamSelection: Sendable { var initialMessages: Int?; var after: Cursor?; var deltaMs: Int? = nil }
struct CoreProjection: Sendable {
    /// Joins Core's synchronous listener, not buffered AsyncStream/UI consumers. A synchronous
    /// close from that listener itself fences without waiting for its own stack.
    /// An app callback that waits for work on the closer's thread deadlocks under any
    /// wait-for-callback fence.
    let close: @Sendable () -> Void
    let history: @Sendable (Int?, Int) async throws -> Void
}
struct UnitEnd: Sendable, Codable { let seq: Int; let inputs: [String]; let pending: [String] }
struct InputObservation: Sendable, Codable { let id: String; let seq: Int; let status: LegacyInputStatus; let carried: Bool }
enum RequestObservation: Sendable, Codable { case input(InputObservation), messageEnd(LegacyMessageEnd), state(LegacyStateEvent), unitEnd(UnitEnd) }
struct CapturedRequestState: Sendable {
    let head: Int; let floor: Int; let status: LegacyInputStatus; let idle: Bool
    let carried: Bool; let unitEnd: UnitEnd?
}
struct RetainedRequestEnds: Sendable { let messages: [LegacyMessageEnd]; let gap: Bool }
protocol CoreStreamPort: Sendable {
    var logId: String { get }
    func observe(_ event: @escaping @Sendable (RequestObservation) -> Void,
                 end: @escaping @Sendable (LegacyStreamError?) -> Void) throws -> @Sendable () -> Void
    func select(_ selection: StreamSelection, event: @escaping @Sendable (LegacyRuntimeEvent) -> Void) -> CoreProjection
    func send(_ input: JSON, options: SendOptions) async throws -> LegacyReceipt
    /// A typed send; a port with an image PAL captures its byte images at the reserved entry.
    func send(_ input: SendInput, options: SendOptions) async throws -> LegacyReceipt
    func readOutcome(id: String, fromSeq: Int, captured: @escaping @Sendable (CapturedRequestState) -> Void) async throws -> RetainedRequestEnds
    func cancel(_ id: String) async throws
    func clearHistory() async throws
}
extension CoreStreamPort {
    func send(_ input: SendInput, options: SendOptions) async throws -> LegacyReceipt {
        guard input.imageCaptures().isEmpty else { throw LegacyCrocheError("image_unsupported", "The image could not be prepared.") }
        return try await send(try input.coreJSON(options: options), options: options)
    }
}
enum RequestCompletion: Sendable { case consumingUnit, idle }

// One predicate for both modes, ready for S1's reviewed unit.end evidence.
// OPEN(§18.24): Atlas must confirm unit.end and capture/retry evidence; no Rust ABI inferred.
private func requestComplete(_ wait: RequestCompletion, status: LegacyInputStatus?, idle: Bool,
                             carried: Bool, unit: UnitEnd?, id: String?) -> Bool {
    guard let id else { return false }
    switch wait {
    case .idle: return status?.terminal == true && idle
    case .consumingUnit: return unit?.inputs.contains(id) == true || (status?.terminal == true && !carried)
    }
}
private final class WaitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var value: Bool { lock.withLock { cancelled } }
}
private final class RequestWaiter {
    var id: String?; let wait: RequestCompletion; let cancellation: WaitCancellation
    let continuation: CheckedContinuation<LegacyRequestResult, Error>
    var receipt: LegacyReceipt?; var status: LegacyInputStatus?; var carried = false
    var messages: [String: LegacyMessageEnd] = [:]
    // Per-call SDK observation bounds; losing observation never cancels Core.
    var beforeReceipt: [(RequestObservation, Int)] = []
    var beforeReceiptBytes = 0
    func dropBeforeReceipt() { beforeReceipt.removeAll(); beforeReceiptBytes = 0 }
    func retain(_ observation: RequestObservation, head: Int) {
        guard !lost, !cancellation.value else { dropBeforeReceipt(); return }
        guard let bytes = try? JSONEncoder().encode(observation).count,
              beforeReceipt.count < 256, beforeReceiptBytes + bytes <= 1_048_576 else {
            lost = true; dropBeforeReceipt(); return
        }
        beforeReceipt.append((observation, head)); beforeReceiptBytes += bytes
    }
    var captured = false
    var reading = true; var complete = false; var cutoff: Int?; var gap = false
    var lost = false
    init(id: String?, wait: RequestCompletion, cancellation: WaitCancellation, continuation: CheckedContinuation<LegacyRequestResult, Error>) {
        self.id = id; self.wait = wait; self.cancellation = cancellation; self.continuation = continuation
    }
    func add(_ message: LegacyMessageEnd) {
        guard let id, message.causedBy.contains(id), cutoff.map({ message.seq <= $0 }) ?? true else { return }
        messages["\(message.id):\(message.seq)"] = message
    }
}

// Every mutable member is under lock. Core callbacks update waiters synchronously;
// the app only receives owned values through its independent queue.
final class StreamHub: @unchecked Sendable {
    private let lock = NSLock()
    private let selectionLock = NSRecursiveLock()
    private let port: any CoreStreamPort
    private var observation: (@Sendable () -> Void)?
    private var projection: CoreProjection?
    private var branch: AppStreamBranch?
    private var waiters: [UUID: RequestWaiter] = [:]
    private var ended = false
    private var observedHead = 0
    private var currentState = LegacyStateEvent(status: .idle, queued: 0, typing: false)
    var state: LegacyStateEvent { lock.withLock { currentState } }
    var logId: String { port.logId }
    init(port: any CoreStreamPort) throws {
        self.port = port
        observation = try port.observe({ [weak self] in self?.receive($0) }, end: { [weak self] in self?.end($0) })
    }
    func events(initialMessages: Int = 50) -> AsyncStream<LegacyRuntimeEvent> {
        return events(StreamSelection(initialMessages: initialMessages, after: nil))
    }
    func events(after: Cursor) -> AsyncStream<LegacyRuntimeEvent> { events(StreamSelection(initialMessages: nil, after: after)) }
    private func events(_ selection: StreamSelection) -> AsyncStream<LegacyRuntimeEvent> { attach(selection).stream }
    func subscribe(_ options: LegacySubscribeOptions) -> LegacyCrocheAgent.Subscription {
        let selection = StreamSelection(initialMessages: options.initialMessages ?? (options.after == nil ? 50 : nil), after: options.after,
                                        deltaMs: options.deltaMs)
        return LegacyCrocheAgent.Subscription(branch: attach(selection), handler: options.onEvent)
    }
    private func attach(_ selection: StreamSelection) -> AppStreamBranch {
        selectionLock.lock(); defer { selectionLock.unlock() }
        // Both the actor façade and synchronous subscribe use this selection fence.
        let app = AppStreamBranch()
        let old: (AppStreamBranch?, CoreProjection?, Bool) = lock.withLock {
            let old = (branch, projection, ended)
            branch = app; projection = nil
            return old
        }
        old.1?.close(); old.0?.finish(.replaced)
        if selection.initialMessages != nil && selection.after != nil {
            app.finish(.streamError(LegacyStreamError(code: "invalid_configuration", message: "Use initialMessages or after, not both", poisoned: false)))
            return app
        }
        if let count = selection.initialMessages, !(0...256).contains(count) {
            app.finish(.streamError(LegacyStreamError(code: "invalid_configuration", message: "initialMessages must be in 0...256", poisoned: false)))
            return app
        }
        if old.2 { app.finish(.streamError(LegacyStreamError(code: "closed", message: "Runtime is closed", poisoned: false))); return app }
        let closeProjection = port.select(selection) { [weak app] in app?.push($0) }
        app.onEnd(closeProjection.close)
        app.setHistory(closeProjection.history)
        lock.withLock { projection = closeProjection }
        return app
    }
    static func errorStream(_ code: String, _ message: String) -> AsyncStream<LegacyRuntimeEvent> {
        AsyncStream { continuation in
            continuation.yield(.streamError(LegacyStreamError(code: code, message: message, poisoned: false)))
            continuation.finish()
        }
    }
    func send(_ input: SendInput, options: SendOptions) async throws -> LegacyReceipt {
        if Task.isCancelled { throw LegacyCrocheError("aborted", "Send cancelled before acceptance") }
        guard !lock.withLock({ ended }) else { throw LegacyCrocheError("closed", "Runtime is closed") }
        return try await port.send(input, options: options)
    }
    func history(before: Int?, limit: Int) async throws {
        guard (1...256).contains(limit) else { throw LegacyCrocheError("invalid_configuration", "history limit must be in 1...256") }
        let selected = lock.withLock { branch?.isActive == true && !ended ? projection : nil }
        guard let selected else { throw LegacyCrocheError("invalid_configuration", "No stream is attached") }
        try await selected.history(before, limit)
    }
    func cancel(_ id: String) async throws { try await port.cancel(id) }
    func clearHistory() async throws { try await port.clearHistory() }
    func request(_ input: SendInput, options: SendOptions = SendOptions(), wait: RequestWait? = nil) async throws -> LegacyRequestResult {
        if Task.isCancelled { throw LegacyCrocheError("aborted", "Request cancelled before sending") }
        // Keel/rook: keep terminal + idle until the coordinated TS/Swift/Kotlin consuming-unit change.
        // Both nil and the approved public .idle use S2's terminal-plus-idle default.
        let completion: RequestCompletion = .idle
        let key = UUID(), cancellation = WaitCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let admitted = lock.withLock {
                    if ended { continuation.resume(throwing: LegacyCrocheError("closed", "Runtime is closed")); return false }
                    if cancellation.value { continuation.resume(throwing: LegacyCrocheError("aborted", "Request cancelled before sending")); return false }
                    waiters[key] = RequestWaiter(id: nil, wait: completion, cancellation: cancellation, continuation: continuation)
                    return true
                }
                guard admitted else { return }
                // Do not cancel the acceptance task when the caller stops waiting.
                Task { await self.accept(input, options: options, key: key) }
            }
        } onCancel: {
            cancellation.cancel()
            self.abort(key)
        }
    }
    private func accept(_ input: SendInput, options: SendOptions, key: UUID) async {
        var receipt: LegacyReceipt?
        do {
            let accepted = try await port.send(input, options: options)
            receipt = accepted
            let read = lock.withLock {
                guard let waiter = waiters[key] else { return false }
                waiter.id = accepted.requestId
                waiter.receipt = accepted
                let early = waiter.beforeReceipt
                waiter.dropBeforeReceipt()
                for (observation, head) in early { apply(observation, key: key, head: head) }
                // A same-id terminal retry emits no new input event. Seed its disposition
                // before idle can overtake capture; never regress a status already observed.
                if waiter.status == nil || (waiter.status?.terminal != true && accepted.status.terminal) {
                    waiter.status = accepted.status
                }
                if waiter.lost { fail(key, code: "observation_lost"); return false }
                if waiter.cancellation.value { fail(key, code: "aborted"); return false }
                if accepted.seq == nil {
                    waiters.removeValue(forKey: key)
                    waiter.continuation.resume(returning: LegacyRequestResult(id: accepted.requestId, status: accepted.status, messages: [], gap: false, legacy: true))
                    return false
                }
                return true
            }
            guard read, let seq = accepted.seq else { return }
            let retained = try await port.readOutcome(id: accepted.requestId, fromSeq: seq) { [weak self] captured in
                self?.capture(captured, key: key, receipt: accepted)
            }
            lock.withLock {
                guard let waiter = waiters[key] else { return }
                guard waiter.captured else { fail(key, code: "observation_lost"); return }
                for message in retained.messages { waiter.add(message) }
                waiter.gap = waiter.gap || retained.gap
                waiter.reading = false
                finish(key)
            }
        } catch {
            lock.withLock {
                guard let waiter = waiters.removeValue(forKey: key) else { return }
                waiter.continuation.resume(throwing: receipt.map { LegacyCrocheError("observation_lost", "Outcome observation failed", receipt: $0) } ?? error)
            }
        }
    }
    private func capture(_ captured: CapturedRequestState, key: UUID, receipt: LegacyReceipt) {
        lock.withLock {
            guard let waiter = waiters[key] else { return }
            waiter.captured = true
            if waiter.status?.terminal != true { waiter.status = captured.status }
            waiter.carried = waiter.carried || captured.carried
            waiter.gap = waiter.gap || receipt.seq! < captured.floor
            // A newly attached hub can finish a terminal retry at idle before it has seen
            // any sequence for that receipt. Its zero/older live cutoff must not discard
            // the scoped retained reply. An actual live completion cut stays unchanged.
            if waiter.complete, let cutoff = waiter.cutoff, cutoff < receipt.seq! {
                waiter.cutoff = captured.head
            }
            if !waiter.complete && requestComplete(waiter.wait, status: waiter.status, idle: captured.idle, carried: waiter.carried, unit: captured.unitEnd, id: waiter.id) {
                waiter.complete = true; waiter.cutoff = captured.head
            }
        }
    }
    private func receive(_ observation: RequestObservation) {
        lock.withLock {
            switch observation {
            case .input(let input): observedHead = max(observedHead, input.seq)
            case .messageEnd(let message): observedHead = max(observedHead, message.seq)
            case .state(let state): currentState = state
            case .unitEnd(let unit): observedHead = max(observedHead, unit.seq)
            }
            for key in Array(waiters.keys) {
                guard let waiter = waiters[key], !waiter.complete else { continue }
                if waiter.id == nil {
                    waiter.retain(observation, head: observedHead)
                    continue
                }
                apply(observation, key: key, head: observedHead)
            }
        }
    }
    // Caller holds lock. Replay uses the head at observation time, not a later head.
    private func apply(_ observation: RequestObservation, key: UUID, head: Int) {
        guard let waiter = waiters[key], !waiter.complete else { return }
        var idle = false, unit: UnitEnd?
        switch observation {
        case .input(let input) where input.id == waiter.id:
            if waiter.status?.terminal != true { waiter.status = input.status }
            waiter.carried = waiter.carried || input.carried
        case .messageEnd(let message): waiter.add(message)
        case .state(let state): idle = state.status == .idle
        case .unitEnd(let value): unit = value
        default: break
        }
        if requestComplete(waiter.wait, status: waiter.status, idle: idle, carried: waiter.carried, unit: unit, id: waiter.id) {
            waiter.complete = true; waiter.cutoff = unit?.seq ?? head
        }
        finish(key)
    }
    private func finish(_ key: UUID) {
        guard let waiter = waiters[key], !waiter.reading, waiter.complete, let receipt = waiter.receipt, let status = waiter.status else { return }
        waiters.removeValue(forKey: key)
        waiter.continuation.resume(returning: LegacyRequestResult(id: receipt.requestId, status: status, messages: waiter.messages.values.sorted { $0.seq < $1.seq }, gap: waiter.gap, legacy: false))
    }
    // Caller must hold lock.
    private func fail(_ key: UUID, code: String) {
        guard let waiter = waiters.removeValue(forKey: key) else { return }
        waiter.continuation.resume(throwing: LegacyCrocheError(code, "The wait ended; accepted input continues", receipt: waiter.receipt))
    }
    private func abort(_ key: UUID) { lock.withLock {
        waiters[key]?.dropBeforeReceipt()
        if waiters[key]?.receipt != nil { fail(key, code: "aborted") }
    } }
    func close() {
        end(LegacyStreamError(code: "closed", message: "Runtime is closed", poisoned: false), drain: false)
        let detach = lock.withLock { let old = observation; observation = nil; return old }
        detach?()
    }
    deinit { observation?(); projection?.close() }
    private func end(_ error: LegacyStreamError?, drain: Bool = true) {
        let old: (AppStreamBranch?, CoreProjection?) = lock.withLock {
            guard !ended else { return (nil, nil) }
            ended = true
            for key in Array(waiters.keys) {
                waiters[key]?.lost = true
                waiters[key]?.dropBeforeReceipt()
                if waiters[key]?.receipt != nil { fail(key, code: "observation_lost") }
            }
            return (branch, projection)
        }
        old.1?.close()
        old.0?.finish(error.map(LegacyRuntimeEvent.streamError), drain: drain && error != nil)
    }
}

// AsyncStream's unfolding form lets this SDK count queued UTF-8 bytes and events.
// Retain the delivered event's budget until next() is called again: the for-await
// body has then finished (Keel ruling 6071234795).
private final class AppStreamBranch: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(LegacyRuntimeEvent, Int)] = []
    private var bytes = 0
    private var inFlightBytes: Int?
    private var active = true
    private var terminal: LegacyRuntimeEvent?
    private var consumer: CheckedContinuation<LegacyRuntimeEvent?, Never>?
    private var closeProjection: (@Sendable () -> Void)?
    private var historyPage: (@Sendable (Int?, Int) async throws -> Void)?
    private var immediateEnd: (@Sendable (LegacyRuntimeEvent?) -> Void)?
    private var immediateReason: LegacyRuntimeEvent?
    private var endedImmediately = false
    func setHistory(_ history: @escaping @Sendable (Int?, Int) async throws -> Void) { lock.withLock { historyPage = history } }
    func history(_ options: LegacyHistoryOptions) async throws {
        guard (1...256).contains(options.limit) else { throw LegacyCrocheError("invalid_configuration", "history limit must be in 1...256") }
        let page = lock.withLock { active ? historyPage : nil }
        guard let page else { throw LegacyCrocheError("invalid_configuration", "No stream is attached") }
        try await page(options.before, options.limit)
    }
    func observeImmediateEnd(_ observer: @escaping @Sendable (LegacyRuntimeEvent?) -> Void) {
        let prior: (Bool, LegacyRuntimeEvent?) = lock.withLock { immediateEnd = observer; return (endedImmediately, immediateReason) }
        if prior.0 { observer(prior.1) }
    }
    var isActive: Bool { lock.withLock { active } }
    var stream: AsyncStream<LegacyRuntimeEvent> {
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.finish(nil) })
    }
    func onEnd(_ close: @escaping @Sendable () -> Void) {
        let alreadyEnded = lock.withLock { closeProjection = close; return !active }
        if alreadyEnded { close() }
    }
    func push(_ event: LegacyRuntimeEvent) {
        if case .replaced = event { finish(event); return }
        if case .streamError = event {
            finish(event, drain: true); return
        }
        let count: Int
        do { count = try event.serializedBytes() }
        catch { finish(.streamError(LegacyStreamError(code: "handler_failed", message: "Event cannot be encoded", poisoned: false))); return }
        let overflow = lock.withLock {
            guard active else { return false }
            if queue.count + (inFlightBytes == nil ? 0 : 1) + 1 > 256 || bytes + count > 1_048_576 { return true }
            if let consumer { self.consumer = nil; inFlightBytes = count; bytes += count; consumer.resume(returning: event); return false }
            queue.append((event, count)); bytes += count
            return false
        }
        if overflow { finish(.streamError(LegacyStreamError(code: "subscriber_overflow", message: "App event buffer exceeded", poisoned: false))) }
    }
    func finish(_ event: LegacyRuntimeEvent?, drain: Bool = false) {
        let result: ((@Sendable () -> Void)?, (@Sendable (LegacyRuntimeEvent?) -> Void)?) = lock.withLock {
            guard active else { return (nil, nil) }
            active = false
            // Keel ruling 6071234795: Core errors drain; SDK-side ends drop queued values.
            if drain {} else { queue.removeAll(); bytes = 0; inFlightBytes = nil }
            terminal = event
            if let consumer { self.consumer = nil; terminal = nil; consumer.resume(returning: event) }
            if !drain { endedImmediately = true; immediateReason = event }
            return (closeProjection, drain ? nil : immediateEnd)
        }
        result.0?()
        result.1?(event)
    }
    private func next() async -> LegacyRuntimeEvent? {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let inFlightBytes { bytes -= inFlightBytes; self.inFlightBytes = nil }
                if !queue.isEmpty { let item = queue.removeFirst(); inFlightBytes = item.1; continuation.resume(returning: item.0) }
                else if !active { let last = terminal; terminal = nil; continuation.resume(returning: last) }
                else { consumer = continuation }
            }
        }
    }
}

extension LegacyRuntimeEvent {
    // Match the flat wire shape; Swift's synthesized enum encoding adds wrappers.
    func serializedBytes() throws -> Int {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(wireJSON()).count
    }
    func wireJSON() throws -> JSON {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.withoutEscapingSlashes]
        func fields<T: Encodable>(_ value: T, _ type: String) throws -> JSON {
            var json = try JSON(data: encoder.encode(value)); json["type"] = .string(type); return json
        }
        let json: JSON
        switch self {
        case .input(let v): json = try fields(v, "input")
        case .messageStart(let v): json = try fields(v, "message.start")
        case .messageDelta(let v): json = try fields(v, "message.delta")
        case .messageEnd(let v): json = try fields(v, "message.end")
        case .cleared(let v): json = try fields(v, "cleared")
        case .app(let v): json = try fields(v, "app")
        case .turn(let v): json = try fields(v, "turn")
        case .state(let v): json = try fields(v, "state")
        case .error(let v): json = try fields(v, "error")
        case .gap(let v): json = try fields(v, "gap")
        case .snapshot(let v): json = try fields(v, "snapshot")
        case .streamError(let v): json = try fields(v, "error")
        case .page(let v):
            json = .object(["type": .string("page"), "messages": .array(try v.messages.map { try $0.wireJSON() }), "reachedFloor": .bool(v.reachedFloor), "logId": .string(v.logId), "clearedSeq": .number(Double(v.clearedSeq))])
        case .replaced: json = .object(["type": .string("replaced")])
        case .unknown(let type, let fields):
            var object = fields.object ?? [:]; object["type"] = .string(type); json = .object(object)
        }
        return json
    }
}


extension LegacyCrocheAgent {
    /// Nested (APP-API, founder 09:21Z): a top-level `Subscription` collides with Combine's.
    /// One serialized application callback branch; requests have an independent observation.
    public final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private let branch: AppStreamBranch
        private let handler: @Sendable (LegacyRuntimeEvent) async -> Void
        private var outcome: LegacyAppStreamEnd?
        private var waits: [CheckedContinuation<LegacyAppStreamEnd, Never>] = []
        private var silenced = false
        private var consumer: Task<Void, Never>?
        fileprivate init(branch: AppStreamBranch, handler: @escaping @Sendable (LegacyRuntimeEvent) async -> Void) {
            self.branch = branch; self.handler = handler
            branch.observeImmediateEnd { [weak self] event in self?.finish(event, notify: true) }
            consumer = Task { [weak self] in
                for await event in branch.stream {
                    guard let self else { return }
                    if self.lock.withLock({ self.outcome != nil }) { return }
                    if Self.reason(event) != nil { self.finish(event, notify: false) }
                    await handler(event)
                }
                self?.finish(nil, notify: false)
            }
        }
        public var ended: LegacyAppStreamEnd {
            get async {
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        if let outcome { continuation.resume(returning: outcome) }
                        else { waits.append(continuation) }
                    }
                }
            }
        }
        public func close() {
            lock.withLock { silenced = true }
            finish(nil, notify: false)
            branch.finish(nil)
            consumer?.cancel()
        }
        public func history(_ options: LegacyHistoryOptions) async throws { try await branch.history(options) }
        private static func reason(_ event: LegacyRuntimeEvent?) -> String? {
            switch event {
            case .streamError(let error): return error.code
            case .replaced: return "replaced"
            default: return nil
            }
        }
        private func finish(_ event: LegacyRuntimeEvent?, notify: Bool) {
            let accepted = lock.withLock {
                guard outcome == nil else { return false }
                let result = LegacyAppStreamEnd(code: Self.reason(event) ?? "closed")
                outcome = result
                for continuation in waits { continuation.resume(returning: result) }
                waits.removeAll(); return true
            }
            if accepted && notify, let event {
                Task { [weak self] in
                    guard let self, !self.lock.withLock({ self.silenced }) else { return }
                    await self.handler(event)
                }
            }
        }
    }
}
