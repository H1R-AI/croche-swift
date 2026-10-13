import Foundation

// Proposed SDK-internal seam only. Core owns projection, ordered capture, delta fences,
// and storage. select/history never allocate a second canonical observation.
struct StreamSelection: Sendable { var initialMessages: Int?; var after: Cursor? }
struct CoreProjection: Sendable {
    /// Joins Core's synchronous listener, not buffered AsyncStream/UI consumers. A synchronous
    /// close from that listener itself fences without waiting for its own stack.
    /// An app callback that waits for work on the closer's thread deadlocks under any
    /// wait-for-callback fence.
    let close: @Sendable () -> Void
    let history: @Sendable (Int?, Int) async throws -> Void
}
struct UnitEnd: Sendable { let seq: Int; let inputs: [String]; let pending: [String] }
struct InputObservation: Sendable { let id: String; let seq: Int; let status: InputStatus; let carried: Bool }
enum RequestObservation: Sendable { case input(InputObservation), messageEnd(MessageEnd), state(StateEvent), unitEnd(UnitEnd) }
struct CapturedRequestState: Sendable {
    let head: Int; let floor: Int; let status: InputStatus; let idle: Bool
    let carried: Bool; let unitEnd: UnitEnd?
}
struct RetainedRequestEnds: Sendable { let messages: [MessageEnd]; let gap: Bool }
protocol CoreStreamPort: Sendable {
    var logId: String { get }
    func observe(_ event: @escaping @Sendable (RequestObservation) -> Void,
                 end: @escaping @Sendable (StreamError?) -> Void) throws -> @Sendable () -> Void
    func select(_ selection: StreamSelection, event: @escaping @Sendable (RuntimeEvent) -> Void) -> CoreProjection
    func send(_ input: JSON, options: SendOptions) async throws -> Receipt
    func readOutcome(id: String, fromSeq: Int, captured: @escaping @Sendable (CapturedRequestState) -> Void) async throws -> RetainedRequestEnds
    func cancel(_ id: String) async throws
    func clearHistory() async throws
}
enum RequestCompletion: Sendable { case consumingUnit, idle }

// One predicate for both modes, ready for S1's reviewed unit.end evidence.
// OPEN(§18.24): Atlas must confirm unit.end and capture/retry evidence; no Rust ABI inferred.
private func requestComplete(_ wait: RequestCompletion, status: InputStatus?, idle: Bool,
                             carried: Bool, unit: UnitEnd?, id: String) -> Bool {
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
    let id: String; let wait: RequestCompletion; let cancellation: WaitCancellation
    let continuation: CheckedContinuation<RequestResult, Error>
    var receipt: Receipt?; var status: InputStatus?; var carried = false
    var messages: [String: MessageEnd] = [:]
    var captured = false
    var reading = true; var complete = false; var cutoff: Int?; var gap = false
    var lost = false
    init(id: String, wait: RequestCompletion, cancellation: WaitCancellation, continuation: CheckedContinuation<RequestResult, Error>) {
        self.id = id; self.wait = wait; self.cancellation = cancellation; self.continuation = continuation
    }
    func add(_ message: MessageEnd) {
        guard message.causedBy.contains(id), cutoff.map({ message.seq <= $0 }) ?? true else { return }
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
    private var currentState = StateEvent(status: .idle, queued: 0, typing: false)
    var state: StateEvent { lock.withLock { currentState } }
    var logId: String { port.logId }
    init(port: any CoreStreamPort) throws {
        self.port = port
        observation = try port.observe({ [weak self] in self?.receive($0) }, end: { [weak self] in self?.end($0) })
    }
    func events(initialMessages: Int = 50) -> AsyncStream<RuntimeEvent> {
        return events(StreamSelection(initialMessages: initialMessages, after: nil))
    }
    func events(after: Cursor) -> AsyncStream<RuntimeEvent> { events(StreamSelection(initialMessages: nil, after: after)) }
    private func events(_ selection: StreamSelection) -> AsyncStream<RuntimeEvent> { attach(selection).stream }
    func subscribe(_ options: SubscribeOptions) -> AgentSubscription {
        let selection = StreamSelection(initialMessages: options.initialMessages ?? (options.after == nil ? 50 : nil), after: options.after)
        return AgentSubscription(branch: attach(selection), handler: options.onEvent)
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
            app.finish(.streamError(StreamError(code: "invalid_configuration", message: "Use initialMessages or after, not both", poisoned: false)))
            return app
        }
        if let count = selection.initialMessages, !(0...256).contains(count) {
            app.finish(.streamError(StreamError(code: "invalid_configuration", message: "initialMessages must be in 0...256", poisoned: false)))
            return app
        }
        if old.2 { app.finish(.streamError(StreamError(code: "closed", message: "Runtime is closed", poisoned: false))); return app }
        let closeProjection = port.select(selection) { [weak app] in app?.push($0) }
        app.onEnd(closeProjection.close)
        app.setHistory(closeProjection.history)
        lock.withLock { projection = closeProjection }
        return app
    }
    static func errorStream(_ code: String, _ message: String) -> AsyncStream<RuntimeEvent> {
        AsyncStream { continuation in
            continuation.yield(.streamError(StreamError(code: code, message: message, poisoned: false)))
            continuation.finish()
        }
    }
    func send(_ input: SendInput, options: SendOptions) async throws -> Receipt {
        if Task.isCancelled { throw CrocheError("aborted", "Send cancelled before acceptance") }
        guard !lock.withLock({ ended }) else { throw CrocheError("closed", "Runtime is closed") }
        return try await port.send(try input.coreJSON(options: options), options: options)
    }
    func history(before: Int?, limit: Int) async throws {
        guard (1...256).contains(limit) else { throw CrocheError("invalid_configuration", "history limit must be in 1...256") }
        let selected = lock.withLock { branch?.isActive == true && !ended ? projection : nil }
        guard let selected else { throw CrocheError("invalid_configuration", "No stream is attached") }
        try await selected.history(before, limit)
    }
    func cancel(_ id: String) async throws { try await port.cancel(id) }
    func clearHistory() async throws { try await port.clearHistory() }
    func request(_ input: SendInput, options: SendOptions = SendOptions(), wait: RequestWait? = nil) async throws -> RequestResult {
        if Task.isCancelled { throw CrocheError("aborted", "Request cancelled before sending") }
        // Keel/rook: keep terminal + idle until the coordinated TS/Swift/Kotlin consuming-unit change.
        // Both nil and the approved public .idle use S2's terminal-plus-idle default.
        let completion: RequestCompletion = .idle
        let key = UUID(), cancellation = WaitCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let admitted = lock.withLock {
                    if ended { continuation.resume(throwing: CrocheError("closed", "Runtime is closed")); return false }
                    if cancellation.value { continuation.resume(throwing: CrocheError("aborted", "Request cancelled before sending")); return false }
                    waiters[key] = RequestWaiter(id: input.id, wait: completion, cancellation: cancellation, continuation: continuation)
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
        var receipt: Receipt?
        do {
            let accepted = try await port.send(try input.coreJSON(options: options), options: options)
            receipt = accepted
            let read = lock.withLock {
                guard let waiter = waiters[key] else { return false }
                waiter.receipt = accepted
                // A same-id terminal retry emits no new input event. Seed its disposition
                // before idle can overtake capture; never regress a status already observed.
                if waiter.status == nil || (waiter.status?.terminal != true && accepted.status.terminal) {
                    waiter.status = accepted.status
                }
                if waiter.lost { fail(key, code: "observation_lost"); return false }
                if waiter.cancellation.value { fail(key, code: "aborted"); return false }
                if accepted.seq == nil {
                    waiters.removeValue(forKey: key)
                    waiter.continuation.resume(returning: RequestResult(id: accepted.id, status: accepted.status, messages: [], gap: false, legacy: true))
                    return false
                }
                return true
            }
            guard read, let seq = accepted.seq else { return }
            let retained = try await port.readOutcome(id: accepted.id, fromSeq: seq) { [weak self] captured in
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
                waiter.continuation.resume(throwing: receipt.map { CrocheError("observation_lost", "Outcome observation failed", receipt: $0) } ?? error)
            }
        }
    }
    private func capture(_ captured: CapturedRequestState, key: UUID, receipt: Receipt) {
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
                    waiter.complete = true; waiter.cutoff = unit?.seq ?? observedHead
                }
                finish(key)
            }
        }
    }
    private func finish(_ key: UUID) {
        guard let waiter = waiters[key], !waiter.reading, waiter.complete, let receipt = waiter.receipt, let status = waiter.status else { return }
        waiters.removeValue(forKey: key)
        waiter.continuation.resume(returning: RequestResult(id: receipt.id, status: status, messages: waiter.messages.values.sorted { $0.seq < $1.seq }, gap: waiter.gap, legacy: false))
    }
    // Caller must hold lock.
    private func fail(_ key: UUID, code: String) {
        guard let waiter = waiters.removeValue(forKey: key) else { return }
        waiter.continuation.resume(throwing: CrocheError(code, "The wait ended; accepted input continues", receipt: waiter.receipt))
    }
    private func abort(_ key: UUID) { lock.withLock { if waiters[key]?.receipt != nil { fail(key, code: "aborted") } } }
    func close() {
        end(StreamError(code: "closed", message: "Runtime is closed", poisoned: false), drain: false)
        let detach = lock.withLock { let old = observation; observation = nil; return old }
        detach?()
    }
    deinit { observation?(); projection?.close() }
    private func end(_ error: StreamError?, drain: Bool = true) {
        let old: (AppStreamBranch?, CoreProjection?) = lock.withLock {
            guard !ended else { return (nil, nil) }
            ended = true
            for key in Array(waiters.keys) {
                waiters[key]?.lost = true
                if waiters[key]?.receipt != nil { fail(key, code: "observation_lost") }
            }
            return (branch, projection)
        }
        old.1?.close()
        old.0?.finish(error.map(RuntimeEvent.streamError), drain: drain && error != nil)
    }
}

// AsyncStream's unfolding form lets this SDK count queued UTF-8 bytes and events.
// Retain the delivered event's budget until next() is called again: the for-await
// body has then finished (Keel ruling 6071234795).
private final class AppStreamBranch: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [(RuntimeEvent, Int)] = []
    private var bytes = 0
    private var inFlightBytes: Int?
    private var active = true
    private var terminal: RuntimeEvent?
    private var consumer: CheckedContinuation<RuntimeEvent?, Never>?
    private var closeProjection: (@Sendable () -> Void)?
    private var historyPage: (@Sendable (Int?, Int) async throws -> Void)?
    private var immediateEnd: (@Sendable (RuntimeEvent?) -> Void)?
    private var immediateReason: RuntimeEvent?
    private var endedImmediately = false
    func setHistory(_ history: @escaping @Sendable (Int?, Int) async throws -> Void) { lock.withLock { historyPage = history } }
    func history(_ options: HistoryOptions) async throws {
        guard (1...256).contains(options.limit) else { throw CrocheError("invalid_configuration", "history limit must be in 1...256") }
        let page = lock.withLock { active ? historyPage : nil }
        guard let page else { throw CrocheError("invalid_configuration", "No stream is attached") }
        try await page(options.before, options.limit)
    }
    func observeImmediateEnd(_ observer: @escaping @Sendable (RuntimeEvent?) -> Void) {
        let prior: (Bool, RuntimeEvent?) = lock.withLock { immediateEnd = observer; return (endedImmediately, immediateReason) }
        if prior.0 { observer(prior.1) }
    }
    var isActive: Bool { lock.withLock { active } }
    var stream: AsyncStream<RuntimeEvent> {
        AsyncStream(unfolding: { await self.next() }, onCancel: { self.finish(nil) })
    }
    func onEnd(_ close: @escaping @Sendable () -> Void) {
        let alreadyEnded = lock.withLock { closeProjection = close; return !active }
        if alreadyEnded { close() }
    }
    func push(_ event: RuntimeEvent) {
        if case .replaced = event { finish(event); return }
        if case .streamError = event {
            finish(event, drain: true); return
        }
        let count: Int
        do { count = try event.serializedBytes() }
        catch { finish(.streamError(StreamError(code: "handler_failed", message: "Event cannot be encoded", poisoned: false))); return }
        let overflow = lock.withLock {
            guard active else { return false }
            if queue.count + (inFlightBytes == nil ? 0 : 1) + 1 > 256 || bytes + count > 1_048_576 { return true }
            if let consumer { self.consumer = nil; inFlightBytes = count; bytes += count; consumer.resume(returning: event); return false }
            queue.append((event, count)); bytes += count
            return false
        }
        if overflow { finish(.streamError(StreamError(code: "subscriber_overflow", message: "App event buffer exceeded", poisoned: false))) }
    }
    func finish(_ event: RuntimeEvent?, drain: Bool = false) {
        let result: ((@Sendable () -> Void)?, (@Sendable (RuntimeEvent?) -> Void)?) = lock.withLock {
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
    private func next() async -> RuntimeEvent? {
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

extension RuntimeEvent {
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
        case .unknown(let type): json = .object(["type": .string(type)])
        }
        return json
    }
}


/// One serialized application callback branch; requests have an independent observation.
public final class AgentSubscription: @unchecked Sendable {
    private let lock = NSLock()
    private let branch: AppStreamBranch
    private let handler: @Sendable (RuntimeEvent) async -> Void
    private var outcome: AppStreamEnd?
    private var waits: [CheckedContinuation<AppStreamEnd, Never>] = []
    private var silenced = false
    private var consumer: Task<Void, Never>?
    fileprivate init(branch: AppStreamBranch, handler: @escaping @Sendable (RuntimeEvent) async -> Void) {
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
    public var ended: AppStreamEnd {
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
    public func history(_ options: HistoryOptions) async throws { try await branch.history(options) }
    private static func reason(_ event: RuntimeEvent?) -> String? {
        switch event {
        case .streamError(let error): return error.code
        case .replaced: return "replaced"
        default: return nil
        }
    }
    private func finish(_ event: RuntimeEvent?, notify: Bool) {
        let accepted = lock.withLock {
            guard outcome == nil else { return false }
            let result = AppStreamEnd(code: Self.reason(event) ?? "closed")
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
