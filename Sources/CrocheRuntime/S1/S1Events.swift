import Foundation

/// The reader types are GENERATED from Core's Rust contract (GeneratedAppStream.swift), as in TS
/// (APP-API: AgentEvent, MessageEnd and InputDisposition). A type this SDK does not know arrives
/// as `.unknown(type:fields:)` with every field kept.
public typealias AgentEvent = AppStreamContract.AgentEvent
public typealias MessageEnd = AppStreamContract.MessageEnd
public typealias InputDisposition = AppStreamContract.InputDisposition
/// `send`'s answer: Core has ACCEPTED the input. `error` is set when the input already failed.
public typealias SendReceipt = AppStreamContract.SendReceipt
/// `request`'s answer: the input is final. `gap` is true when Core says so, nil when absent.
public typealias RequestResult = AppStreamContract.RequestResult
/// `{code, category, message}` on a failed receipt, result, input or message.
public typealias EventError = AppStreamContract.EventError

public struct SubscribeOptions: Sendable {
    public var initialMessages: Int?
    public var after: Cursor?
    /// How Core batches `messageDelta`. Nil = omitted: Core applies its platform default. The SDK
    /// sets none and passes a value (0 included) to Core unchanged.
    public var deltaMs: Int?
    /// A throw reaches Core as the delivery's `threw` fact; Core decides what follows.
    public var onEvent: @Sendable (AgentEvent) async throws -> Void
    public init(initialMessages: Int? = nil, after: Cursor? = nil, deltaMs: Int? = nil,
                onEvent: @escaping @Sendable (AgentEvent) async throws -> Void) {
        self.initialMessages = initialMessages; self.after = after; self.deltaMs = deltaMs; self.onEvent = onEvent
    }
}
