import Foundation
import CrocheFFI

// The only stream adapter to UniFFI. Core owns projection, ordering and capture.
// Keep the receipt method spelling in this one file/call site for the reviewed rename.
final class FFIStreamPort: CoreStreamPort, @unchecked Sendable {
    private let core: CoreRuntime
    private let images: NativeImagePal?
    let logId: String
    init(core: CoreRuntime, images: NativeImagePal? = nil) throws {
        self.core = core; self.images = images
        logId = try Self.blocking { try core.logId() }
    }
    private final class Box<T>: @unchecked Sendable { var result: Result<T, Error>? }
    // select/observe are synchronous seams. Main-thread callers wait on a dedicated thread;
    // callbacks already on a Core thread stay there, preserving FFI's reentrancy rule.
    private static func blocking<T>(record: Bool = true, _ body: @escaping @Sendable () throws -> T) throws -> T {
        let measured: @Sendable () throws -> T = {
            if record { Offload.starting?() }
            return try body()
        }
        if !Thread.isMainThread { return try measured() }
        let done = DispatchSemaphore(value: 0), box = Box<T>()
        Thread.detachNewThread { box.result = Result { try measured() }; done.signal() }
        done.wait()
        return try box.result!.get()
    }
    private static func offload<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Offload.run(body)
    }
    private final class Listener: EventListener, @unchecked Sendable {
        let callback: @Sendable (String) -> Void
        init(_ callback: @escaping @Sendable (String) -> Void) { self.callback = callback }
        func onEvent(event: String) { callback(event) }
    }
    private static func failure(_ error: Error) -> LegacyStreamError {
        let error = LegacyCrocheError(error)
        return LegacyStreamError(code: error.code, message: error.message, poisoned: false)
    }
    func observe(_ event: @escaping @Sendable (RequestObservation) -> Void,
                 end: @escaping @Sendable (LegacyStreamError?) -> Void) throws -> @Sendable () -> Void {
        do {
            try Self.blocking { [core] in
                try core.observe(onEvent: Listener { text in
                    do {
                        let decoded = try CoreEvent.decode(text)
                        switch decoded {
                        case .input(let v): event(.input(InputObservation(id: v.id, seq: v.seq, status: v.status, carried: v.status == .seen)))
                        case .messageEnd(let v): event(.messageEnd(v))
                        case .state(let v): event(.state(v))
                        default: break
                        }
                    } catch { end(Self.failure(error)) }
                }, onEnd: Listener { text in
                    do { end(try CoreEvent.decodeFailure(text)) }
                    catch { end(Self.failure(error)) }
                })
            }
        } catch { throw LegacyCrocheError(error) }
        return { [core] in _ = try? Self.blocking { core.unobserve() } }
    }
    /// Core's selection JSON. A nil field is omitted (Core's default), never filled in here.
    static func selectionText(_ selection: StreamSelection) throws -> String {
        struct Selection: Encodable { let initialMessages: Int?; let after: Cursor?; let deltaMs: Int? }
        let value = Selection(initialMessages: selection.initialMessages, after: selection.after, deltaMs: selection.deltaMs)
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    func select(_ selection: StreamSelection, event: @escaping @Sendable (LegacyRuntimeEvent) -> Void) -> CoreProjection {
        do {
            if let after = selection.after { _ = try Self.coreSequence(after.seq) }
            let text = try Self.selectionText(selection)
            let id = try Self.blocking { [core] in
                try core.select(selection: text, onEvent: Listener { text in
                    do { event(try CoreEvent.decode(text)) }
                    catch { event(.streamError(Self.failure(error))) }
                })
            }
            return CoreProjection(close: { [core] in _ = try? Self.blocking { core.closeProjection(id: id) } }, history: { before, limit in
                guard let count = UInt32(exactly: limit) else { throw LegacyCrocheError("invalid_configuration", "Invalid history range") }
                let seq = try before.map(Self.coreSequence)
                try await Self.offload { try self.historyNow(id: id, before: seq, limit: count) }
            })
        } catch {
            event(.streamError(Self.failure(error)))
            return CoreProjection(close: {}, history: { _, _ in throw LegacyCrocheError("invalid_configuration", "No stream is attached") })
        }
    }
    // Also used at the synchronous callback boundary to retain FFI's reentrancy rule.
    func historyNow(id: UInt64, before: UInt64?, limit: UInt32) throws {
        try Self.blocking { [core] in try core.history(id: id, before: before, limit: limit) }
    }
    func send(_ input: JSON, options: SendOptions) async throws -> LegacyReceipt {
        let token = CancelToken()
        return try await withTaskCancellationHandler {
            try await send(input, options: options, cancel: token)
        } onCancel: { token.cancel() }
    }
    func send(_ input: JSON, options: SendOptions, cancel: CancelToken?) async throws -> LegacyReceipt {
        let text = String(decoding: try input.encoded(), as: UTF8.self)
        let format = try options.responseFormat.map { String(decoding: try $0.encoded(), as: UTF8.self) }
        let value = try await Self.offload { [core] in try core.send(input: text, cancel: cancel, responseFormat: format) }
        struct WireReceipt: Decodable { let requestId: String; let status: LegacyInputStatus; let seq: Int? }
        let receipt = try CoreEvent.decodeValue(WireReceipt.self, value)
        return LegacyReceipt(requestId: receipt.requestId, status: receipt.status, seq: receipt.seq)
    }
    /// Byte images go through Core's reserved entry: reserve, capture, submit, all before the
    /// first await, so the send keeps its place; only the receipt wait is offloaded. Until submit
    /// returns, this owns the captures; afterwards Core releases them on every exit.
    func send(_ input: SendInput, options: SendOptions) async throws -> LegacyReceipt {
        let captured = input.imageCaptures()
        guard !captured.isEmpty else { return try await send(try input.coreJSON(options: options), options: options) }
        guard let images else { throw LegacyCrocheError("image_unsupported", "The image could not be prepared.") }
        let text = String(decoding: try input.coreJSON(options: options).encoded(), as: UTF8.self)
        let format = try options.responseFormat.map { String(decoding: try $0.encoded(), as: UTF8.self) }
        let token = CancelToken()
        let pending = try Self.blocking { [core] () throws -> PendingSend in
            let entry = try core.reserveSend()
            var tokens: [String] = []
            do {
                var captures: [PalCapturedImageSource] = []
                for (element, bytes) in captured {
                    let capture = try images.capture(bytes)
                    tokens.append(capture)
                    captures.append(PalCapturedImageSource(element: UInt32(element), kind: "encoded-v1", token: capture))
                }
                return try entry.submit(input: text, captures: captures, cancel: token, responseFormat: format)
            } catch {
                for capture in tokens { images.release(capture) }
                throw error
            }
        }
        let value = try await withTaskCancellationHandler {
            try await Self.offload { try pending.wait() }
        } onCancel: { token.cancel() }
        struct WireReceipt: Decodable { let requestId: String; let status: LegacyInputStatus; let seq: Int? }
        let receipt = try CoreEvent.decodeValue(WireReceipt.self, value)
        return LegacyReceipt(requestId: receipt.requestId, status: receipt.status, seq: receipt.seq)
    }
    func readOutcome(id: String, fromSeq: Int, captured: @escaping @Sendable (CapturedRequestState) -> Void) async throws -> RetainedRequestEnds {
        let seq = try Self.coreSequence(fromSeq)
        // Capture parsing failures must fail the read, never silently strand a waiter.
        let captureError = CaptureError()
        let text = try await Self.offload { [core] in
            try core.readOutcome(id: id, fromSeq: seq, captured: Listener { value in
                do {
                    struct Capture: Decodable { let head: Int; let floor: Int; let status: LegacyInputStatus; let idle: Bool; let consumedBy: String? }
                    let at = try CoreEvent.decodeValue(Capture.self, value)
                    captured(CapturedRequestState(head: at.head, floor: at.floor, status: at.status, idle: at.idle, carried: at.consumedBy != nil, unitEnd: nil))
                } catch { captureError.set(error) }
            })
        }
        if let error = captureError.get() { throw error }
        struct Outcome: Decodable { let messages: [LegacyMessageEnd]; let gap: Bool? }
        let outcome = try CoreEvent.decodeValue(Outcome.self, text)
        return RetainedRequestEnds(messages: outcome.messages, gap: outcome.gap ?? false)
    }
    private final class CaptureError: @unchecked Sendable {
        private let lock = NSLock(); private var error: Error?
        func set(_ value: Error) { lock.withLock { error = value } }
        func get() -> Error? { lock.withLock { error } }
    }
    static func coreSequence(_ value: Int) throws -> UInt64 {
        guard let result = UInt64(exactly: value) else { throw LegacyCrocheError("invalid_input", "Sequence is outside the Core range") }
        return result
    }
    func cancel(_ id: String) async throws {
        try await Self.offload { [core] in try core.cancel(id: id) }
    }
    func clearHistory() async throws {
        // Preserve the existing admission fence: only waiting crosses the offload hop.
        let pending = try Self.blocking(record: false) { [core] in core.beginClearHistory() }
        try await Self.offload { try pending.finish() }
    }
}

// Decode numbers from the original JSON bytes, never through the legacy Double JSON tree.
// Extra Core keys stay internal; unknown event types remain forward-compatible.
enum CoreEvent {
    static func publicSequence(_ value: UInt64) throws -> Int {
        guard let result = Int(exactly: value) else { throw LegacyCrocheError("invalid_input", "Core sequence is outside the public range") }
        return result
    }
    // Validate only Core envelope fields, never arbitrary app data/output or usage values.
    private struct Sequences: Decodable {
        enum Keys: String, CodingKey { case seq, firstSeq, clearedSeq, head, floor, afterSeq, throughSeq, messages, streaming }
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            for key in [Keys.seq, .firstSeq, .clearedSeq, .head, .floor, .afterSeq, .throughSeq] {
                if keys.contains(key), !(try keys.decodeNil(forKey: key)) {
                    let value: UInt64
                    do { value = try keys.decode(UInt64.self, forKey: key) }
                    catch { throw LegacyCrocheError("invalid_input", "Invalid Core sequence") }
                    _ = try CoreEvent.publicSequence(value)
                }
            }
            _ = try keys.decodeIfPresent([Sequences].self, forKey: .messages)
            _ = try keys.decodeIfPresent(Sequences.self, forKey: .streaming)
        }
    }
    static func decodeValue<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        let bytes = Data(text.utf8)
        _ = try decoder().decode(Sequences.self, from: bytes)
        return try decoder().decode(type, from: bytes)
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let text = try value.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
                throw LegacyCrocheError("invalid_input", "Invalid Core event date")
            }
            return date
        }
        return decoder
    }
    private struct Failure: Decodable { let code: String; let message: String; let poisoned: Bool? }
    static func decodeFailure(_ text: String) throws -> LegacyStreamError {
        let value = try decoder().decode(Failure.self, from: Data(text.utf8))
        return LegacyStreamError(code: value.code, message: value.message, poisoned: value.poisoned ?? false)
    }
    private struct Event: Decodable {
        let value: LegacyRuntimeEvent
        enum Keys: String, CodingKey { case type, seq, images, messages, reachedFloor, logId, clearedSeq }
        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            let type = try keys.decode(String.self, forKey: .type)
            switch type {
            case "input":
                struct Input: Decodable { let seq: Int; let firstSeq: Int; let id: String; let kind: InputKind; let text: String?; let images: [LegacyImageSummary]?; let status: LegacyInputStatus; let error: LegacyRuntimeError?; let at: Date }
                let v = try Input(from: decoder)
                value = .input(LegacyInputEvent(seq: v.seq, firstSeq: v.firstSeq, id: v.id, kind: v.kind, text: v.text, images: v.images ?? [], status: v.status, error: v.error, at: v.at))
            case "message.start": value = .messageStart(try LegacyMessageStart(from: decoder))
            case "message.delta": value = .messageDelta(try LegacyMessageDelta(from: decoder))
            case "message.end": value = .messageEnd(try LegacyMessageEnd(from: decoder))
            case "state": value = .state(try LegacyStateEvent(from: decoder))
            case "snapshot": value = .snapshot(try LegacySnapshot(from: decoder))
            case "gap": value = .gap(try LegacyGap(from: decoder))
            case "app": value = .app(try LegacyAppStreamEvent(from: decoder))
            case "turn": value = .turn(try LegacyTurnEvent(from: decoder))
            case "cleared": value = .cleared(try LegacyCleared(from: decoder))
            case "error":
                if keys.contains(.seq) { value = .error(try LegacyErrorEvent(from: decoder)) }
                else {
                    let e = try Failure(from: decoder)
                    value = .streamError(LegacyStreamError(code: e.code, message: e.message, poisoned: e.poisoned ?? false))
                }
            case "page": value = .page(LegacyPage(messages: try keys.decode([Event].self, forKey: .messages).map(\.value), reachedFloor: try keys.decode(Bool.self, forKey: .reachedFloor), logId: try keys.decode(String.self, forKey: .logId), clearedSeq: try keys.decode(Int.self, forKey: .clearedSeq)))
            case "replaced": value = .replaced
            default:
                var fields = try JSON(from: decoder).object ?? [:]
                fields.removeValue(forKey: "type")
                value = .unknown(type: type, fields: .object(fields))
            }
        }
    }
    static func decode(_ text: String) throws -> LegacyRuntimeEvent { try decodeValue(Event.self, text).value }
}
