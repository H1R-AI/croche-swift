import Foundation

/// Core's calls block their thread while the host performs effects: run them on a thread of
/// their own, never on the cooperative pool or the main thread.
enum Offload {
    /// Croche's own tests: runs first on each offload thread, so a test can delay it the way the
    /// OS may (#346). Nil in every app.
    nonisolated(unsafe) static var starting: (@Sendable () -> Void)?
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                starting?()
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: LegacyCrocheError(error)) }
            }
        }
    }
}

/// Core's storage identity for a config: the key a store is bound to. Internal; apps never read it.
func storageIdentity(config: JSON) throws -> JSON {
    do { return publicStorageIdentity(try JSON(ffiIdentity(String(decoding: try config.encoded(), as: UTF8.self)))) }
    catch { throw LegacyCrocheError(error) }
}
