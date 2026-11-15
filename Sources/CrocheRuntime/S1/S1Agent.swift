import Foundation
import CrocheFFI

public struct MemoryItem: Sendable, Equatable {
    public let id: String
    public let text: String
    /// The whole item, including fields this SDK does not read.
    public let fields: JSON
}

/// One instance, self-contained.
public final class CrocheAgent: Sendable {
    let core: CoreAgent
    public let id: String
    /// nil = the default instance.
    public let instance: String?
    init(core: CoreAgent) { self.core = core; id = core.id(); instance = core.instance() }

    /// Returns when Core has ACCEPTED the input. Cancelling the Task before acceptance = never
    /// queued; after it = `aborted` (the input continues).
    public func send(_ text: String, _ options: SendOptions = SendOptions()) async throws -> SendReceipt {
        try await send(SendInput(input: [.text(text)]), options)
    }
    public func send(_ input: SendInput, _ options: SendOptions = SendOptions()) async throws -> SendReceipt {
        let core = self.core, (input, images, options) = try Self.wire(input, options.responseFormat, wait: nil)
        return try Self.receipt(try await cancellable { try core.send(inputJson: input, images: images, optionsJson: options, cancel: $0) })
    }
    /// Core's reply decodes straight into the generated contract type, `error` included.
    static func receipt(_ value: String) throws -> SendReceipt { try decode(SendReceipt.self, value) }

    /// Returns when the input is final; with `wait: .idle`, when the agent is idle too.
    public func request(_ text: String, _ options: RequestOptions = RequestOptions()) async throws -> RequestResult {
        try await request(SendInput(input: [.text(text)]), options)
    }
    public func request(_ input: SendInput, _ options: RequestOptions = RequestOptions()) async throws -> RequestResult {
        let core = self.core, (input, images, options) = try Self.wire(input, options.responseFormat, wait: options.wait)
        return try Self.requestResult(try await cancellable { try core.request(inputJson: input, images: images, optionsJson: options, cancel: $0) })
    }
    static func requestResult(_ value: String) throws -> RequestResult { try decode(RequestResult.self, value) }

    /// Byte images ride beside the JSON as owned bytes indexed into `input` (the element is
    /// `{type: image, alt?}`; Core joins the position); never base64. Core sniffs and validates them.
    static func wire(_ input: SendInput, _ responseFormat: JSON?, wait: RequestWait?) throws -> (String, [CoreImageInput], String?) {
        let images = input.imageCaptures().map { CoreImageInput(element: UInt32($0.element), bytes: $0.bytes) }
        var options: [String: JSON] = [:]
        if let responseFormat { options["responseFormat"] = responseFormat }
        if wait == .idle { options["wait"] = .string("idle") }
        return (text(try input.wireJSON()), images, options.isEmpty ? nil : text(.object(options)))
    }

    /// `onEvent` runs serially on the main thread; a delivery counts as handled once it returns.
    /// Core's refusal is thrown unchanged, as in every SDK.
    public func subscribe(_ options: SubscribeOptions) throws -> Subscription {
        var selection: [String: JSON] = [:]
        if let initialMessages = options.initialMessages { selection["initialMessages"] = .number(Double(initialMessages)) }
        if let after = options.after { selection["after"] = .object(["logId": .string(after.logId), "seq": .number(Double(after.seq))]) }
        if let deltaMs = options.deltaMs { selection["deltaMs"] = .number(Double(deltaMs)) }
        let selectionJson = text(.object(selection))
        do { return Subscription(core: try core.subscribe(selectionJson: selectionJson, eventSink: EventSinkAdapter(options.onEvent))) }
        catch { throw CrocheError(error) }
    }

    /// The one cross-handle cancel; returns once Core has durably recorded it.
    public func cancel(_ id: String? = nil) async throws {
        let core = self.core
        try await blocking { try core.cancel(inputId: id) }
    }
    /// The app empties its list on the `cleared` event.
    public func clearHistory() async throws {
        let core = self.core
        try await blocking { try core.clearHistory() }
    }
    public var memory: Memory { Memory(core: core) }

    /// As if `agent()` had opened with this list, from the NEXT turn; may widen past it.
    public func setTools(_ scope: ToolScope) async throws {
        let core = self.core, scope = text(scope.json(\.json))
        try await blocking { try core.setTools(scopeJson: scope) }
    }
    /// Back to `agent()`'s open scope.
    public func resetTools() async throws {
        let core = self.core
        try await blocking { try core.resetTools() }
    }
    public func setWiki(_ scope: WikiScope) async throws {
        let core = self.core, scope = text(scope.json(\.json))
        try await blocking { try core.setWiki(scopeJson: scope) }
    }
    public func resetWiki() async throws {
        let core = self.core
        try await blocking { try core.resetWiki() }
    }
    public func close() async throws {
        let core = self.core
        try await blocking { try core.shutdown() }
    }

    public struct Memory: Sendable {
        let core: CoreAgent
        public func list() async throws -> [MemoryItem] {
            let core = self.core
            guard let items = try reply(try await blocking { try core.memoryList() }).array else { throw malformed("memory list") }
            return try items.map { item in
                guard let id = item["id"].string, let text = item["text"].string else { throw malformed("memory item") }
                return MemoryItem(id: id, text: text, fields: item)
            }
        }
        public func delete(_ id: String) async throws {
            let core = self.core
            try await blocking { try core.memoryDelete(id: id) }
        }
        public func clear() async throws {
            let core = self.core
            try await blocking { try core.memoryClear() }
        }
        public func enabled(_ on: Bool) async throws {
            let core = self.core
            try await blocking { try core.memoryEnabled(on: on) }
        }
    }

    /// Nested: a top-level `Subscription` collides with Combine's.
    public final class Subscription: Sendable {
        let core: CoreSubscription
        init(core: CoreSubscription) { self.core = core }
        /// Older pages, as `page` events on the same `onEvent`.
        public func history(before: Int? = nil, limit: Int) async throws {
            let core = self.core
            var options: [String: JSON] = ["limit": .number(Double(limit))]
            if let before { options["before"] = .number(Double(before)) }
            let text = text(.object(options))
            try await blocking { try core.history(optionsJson: text) }
        }
        public func close() { core.shutdown() }
        public var ended: Bool { core.ended() }
    }
}

func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    do { return try JSONDecoder().decode(type, from: Data(text.utf8)) }
    catch { throw CrocheError(code: "internal", message: "Core's reply is malformed.", category: .internal) }
}

/// Core's event delivery. Decodes with the GENERATED reader, posts to the main thread; on THAT
/// stack, `tryEnter` immediately before the app's handler (false = no entry), then reports how it
/// finished: `returned`, or `threw` with the thrown value's facts (TS events.ts). Core assigns the
/// codes (`handler_failed`). No SDK queue, no wait at close: queue and close policy are Core's.
final class EventSinkAdapter: CoreEventSink, @unchecked Sendable {
    private let onEvent: @Sendable (AgentEvent) async throws -> Void
    init(_ onEvent: @escaping @Sendable (AgentEvent) async throws -> Void) { self.onEvent = onEvent }

    static let returned = #"{"outcome":"returned"}"#
    /// `{outcome:"threw", error:{name, message, code?}}`: facts only, as TS `thrownFacts`.
    static func threw(_ error: Error) -> String {
        var facts: [String: JSON] = ["name": .string(String(reflecting: type(of: error)))]
        if let error = error as? CrocheError {
            facts["message"] = .string(error.message); facts["code"] = .string(error.code)
        } else {
            facts["message"] = .string("\(error)")
        }
        return (strictText(.object(["outcome": .string("threw"), "error": .object(facts)]))) ?? #"{"outcome":"threw"}"#
    }

    func deliver(deliveryId: String, eventJson: String, delivery: CoreDelivery) throws {
        try deliver(eventJson, delivery)
    }

    /// The seam tests drive with a fake gate (Keel 14:40Z); Core's side of the fence is proven in
    /// Rust/WASM with `for_tests`. Returns the main-actor task.
    @discardableResult
    func deliver(_ eventJson: String, _ delivery: any DeliveryGate) throws -> Task<Void, Never> {
        let event: AgentEvent
        do { event = try JSONDecoder().decode(AgentEvent.self, from: Data(eventJson.utf8)) }
        catch { throw MalformedEvent(reason: "\(error)") }
        let onEvent = self.onEvent
        return Task { @MainActor in
            guard delivery.tryEnter() else { return }
            do { try await onEvent(event); delivery.complete(outcomeJson: Self.returned) }
            catch { delivery.complete(outcomeJson: Self.threw(error)) }
        }
    }
}

/// A Core event the generated reader cannot read. The sink has NO error codes (Atlas's PAL error
/// contract): this untyped transport exception reaches Core, which classifies it (`internal`).
struct MalformedEvent: Error, CustomStringConvertible {
    let reason: String
    var description: String { "Core's event is not an AgentEvent: \(reason)" }
}

/// Core's per-delivery fence: entry is checked on the handler's own stack, then the outcome reported.
protocol DeliveryGate: Sendable {
    func tryEnter() -> Bool
    func complete(outcomeJson: String)
}
extension CoreDelivery: DeliveryGate {}
