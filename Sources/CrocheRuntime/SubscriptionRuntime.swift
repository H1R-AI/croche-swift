import Foundation

#if CROCHE_SUBSCRIPTION_HOST
/// Host-only stand-in for the agent class: the namespace `Subscription` nests in.
enum LegacyCrocheAgent {}
// Test-only façade, same public type and forwarding methods as the FFI build.
// Fake Core is supplied by tests, never a production create implementation.
actor AgentEngine {
    let subscriptionHub: StreamHub?
    public nonisolated let logId: String
    init(port: any CoreStreamPort) throws { subscriptionHub = try StreamHub(port: port); logId = port.logId }
    public func clearHistory() async throws { try await subscriptionHub?.clearHistory() }
    public func close() async throws { subscriptionHub?.close() }
}
#endif

extension AgentEngine {
    public func events(initialMessages: Int = 50) -> AsyncStream<LegacyRuntimeEvent> {
        subscriptionHub?.events(initialMessages: initialMessages) ?? StreamHub.errorStream("invalid_configuration", "Subscription Core port is not bound")
    }
    public func events(after: Cursor) -> AsyncStream<LegacyRuntimeEvent> {
        subscriptionHub?.events(after: after) ?? StreamHub.errorStream("invalid_configuration", "Subscription Core port is not bound")
    }
    /// SDK shorthand only; Core generates the id and validates the request.
    public func send(_ text: String, options: SendOptions = SendOptions()) async throws -> LegacyReceipt {
        try await send(SendInput(input: [.text(text, kind: .user)]), options: options)
    }
    public func send(_ input: SendInput, options: SendOptions = SendOptions()) async throws -> LegacyReceipt {
        guard let hub = subscriptionHub else { throw LegacyCrocheError("invalid_configuration", "Subscription Core port is not bound") }
        return try await hub.send(input, options: options)
    }
    public func request(_ input: SendInput, options: SendOptions = SendOptions(), wait: RequestWait? = nil) async throws -> LegacyRequestResult {
        guard let hub = subscriptionHub else { throw LegacyCrocheError("invalid_configuration", "Subscription Core port is not bound") }
        return try await hub.request(input, options: options, wait: wait)
    }
    public func cancel(_ id: String) async throws {
        guard let hub = subscriptionHub else { throw LegacyCrocheError("invalid_configuration", "Subscription Core port is not bound") }
        try await hub.cancel(id)
    }
    public func history(before: Int? = nil, limit: Int) async throws {
        guard let hub = subscriptionHub else { throw LegacyCrocheError("invalid_configuration", "Subscription Core port is not bound") }
        try await hub.history(before: before, limit: limit)
    }
}
