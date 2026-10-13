import Foundation

#if CROCHE_SUBSCRIPTION_HOST
// Test-only façade, same public type and forwarding methods as the FFI build.
// Fake Core is supplied by tests, never a production create implementation.
public actor CrocheRuntime {
    let subscriptionHub: StreamHub?
    public nonisolated let logId: String
    init(port: any CoreStreamPort) throws { subscriptionHub = try StreamHub(port: port); logId = port.logId }
    public func clearHistory() async throws { try await subscriptionHub?.clearHistory() }
    public func close() async throws { subscriptionHub?.close() }
}
#endif

extension CrocheRuntime {
    public func events(initialMessages: Int = 50) -> AsyncStream<RuntimeEvent> {
        subscriptionHub?.events(initialMessages: initialMessages) ?? StreamHub.errorStream("invalid_configuration", "Subscription Core port is not bound")
    }
    public func events(after: Cursor) -> AsyncStream<RuntimeEvent> {
        subscriptionHub?.events(after: after) ?? StreamHub.errorStream("invalid_configuration", "Subscription Core port is not bound")
    }
    public func send(_ input: SendInput, options: SendOptions = SendOptions()) async throws -> Receipt {
        guard let hub = subscriptionHub else { throw CrocheError("invalid_configuration", "Subscription Core port is not bound") }
        return try await hub.send(input, options: options)
    }
    public func request(_ input: SendInput, options: SendOptions = SendOptions(), wait: RequestWait? = nil) async throws -> RequestResult {
        guard let hub = subscriptionHub else { throw CrocheError("invalid_configuration", "Subscription Core port is not bound") }
        return try await hub.request(input, options: options, wait: wait)
    }
    public func cancel(_ id: String) async throws {
        guard let hub = subscriptionHub else { throw CrocheError("invalid_configuration", "Subscription Core port is not bound") }
        try await hub.cancel(id)
    }
    public func history(before: Int? = nil, limit: Int) async throws {
        guard let hub = subscriptionHub else { throw CrocheError("invalid_configuration", "Subscription Core port is not bound") }
        try await hub.history(before: before, limit: limit)
    }
}
