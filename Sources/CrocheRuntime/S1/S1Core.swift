import Foundation
import CrocheFFI

// The 0.6 App API (docs/APP-API.md) over Core's S1 handle ABI: the module's public names. The
// legacy engine's facade stays internal (Legacy*) until its last caller, the RN iOS bridge, moves
// to S1 (Keel 21:58Z). Every value the app gives is passed to Core unchanged as JSON; this layer
// decides nothing.

/// The ONE closed set (APP-API), generated from Core's contract. Core attaches it to every code; the
/// SDK never derives it.
public typealias ErrorCategory = AppStreamContract.ErrorCategory

public struct CrocheError: Error, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let category: ErrorCategory
    /// Where in the app's value Core found the fault (a manifest, scope or bind), when it says.
    public let path: String?
    public let retryAfter: UInt64?
    init(code: String, message: String, category: ErrorCategory, path: String? = nil, retryAfter: UInt64? = nil) {
        self.code = code; self.message = message; self.category = category; self.path = path; self.retryAfter = retryAfter
    }
    /// Core's carrier, passed through. A category outside the closed set is a Core bug: `internal`.
    init(_ error: CoreApiError) {
        switch error {
        // Core's `detail` is the public message (UniFFI reserves `message`).
        case let .Failure(code, detail, category, path, retryAfter):
            self.init(code: code, message: detail, category: ErrorCategory(rawValue: category) ?? .internal, path: path, retryAfter: retryAfter)
        }
    }
    /// Anything else a call threw (the binding's own errors) is code `internal`, literally, category internal (Keel #9).
    init(_ error: Error) {
        if let e = error as? CrocheError { self = e }
        else if let e = error as? CoreApiError { self.init(e) }
        else { self.init(code: "internal", message: "\(error)", category: .internal) }
    }
    public var description: String { "\(code): \(message)" }
}

/// Core's calls block their thread while the host performs effects: run them on a thread of
/// their own, never on the cooperative pool or the main thread.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            Offload.starting?()
            do { continuation.resume(returning: try body()) }
            catch { continuation.resume(throwing: CrocheError(error)) }
        }
    }
}

/// As `blocking`, with a Core token the awaiting Task's cancellation fires (APP-API: cancelling
/// the Task is Swift's signal). A fresh token even when nothing cancels: Core requires one.
/// Where the app's async code runs when Core calls it (a tool's execute, a custom StoragePal), where
/// the OS has task executors: GCD threads apart from Swift's cooperative pool, so app code that
/// blocks its thread never starves the SDK's own work or another call (#342).
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
final class ToolThreads: TaskExecutor, @unchecked Sendable {
    static let shared = ToolThreads()
    private let queue = DispatchQueue(label: "dev.croche.tools", attributes: .concurrent)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job), executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// Starts the app's async code for a Core callback on `ToolThreads` (the cooperative pool on an
/// OS without task executors).
@discardableResult
func appTask(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
        return Task(executorPreference: ToolThreads.shared) { await body() }
    }
    return Task { await body() }
}

/// A Core call that hands back an OWNER (an open Croche, an agent). Cancelling the caller's Task
/// resumes the caller at once with `cancelled`; Core has no token for these calls, so the call
/// finishes on its own thread, and an owner that arrives after the cancellation is shut down
/// there (`discard`), never leaked holding its store or instance lock (Keel ruling #4).
func owner<T: Sendable>(_ body: @escaping @Sendable () throws -> T, discard: @escaping @Sendable (T) -> Void) async throws -> T {
    let pending = Pending<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard pending.wait(continuation) else { return }
            Thread.detachNewThread {
                Offload.starting?()
                let result = Result { try body() }.mapError { CrocheError($0) as Error }
                if !pending.finish(result), case .success(let value) = result { discard(value) }
            }
        }
    } onCancel: { pending.cancel() }
}

/// One caller's wait: whichever of the result and the cancellation comes first resumes it.
private final class Pending<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false, done = false
    private static var cancellation: CrocheError {
        CrocheError(code: "cancelled", message: "The caller's Task was cancelled.", category: .closed)
    }
    /// false = already cancelled (resumed here); start nothing.
    func wait(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        let cancelled = lock.withLock { () -> Bool in
            if self.cancelled { done = true; return true }
            self.continuation = continuation; return false
        }
        if cancelled { continuation.resume(throwing: Self.cancellation) }
        return !cancelled
    }
    func cancel() {
        let waiting = lock.withLock { () -> CheckedContinuation<T, Error>? in
            cancelled = true
            guard !done, let continuation else { return nil }
            done = true; return continuation
        }
        waiting?.resume(throwing: Self.cancellation)
    }
    /// false = the caller already left: the result is unclaimed.
    func finish(_ result: Result<T, Error>) -> Bool {
        let waiting = lock.withLock { () -> CheckedContinuation<T, Error>? in
            guard !done, let continuation else { return nil }
            done = true; return continuation
        }
        waiting?.resume(with: result)
        return waiting != nil
    }
}

func cancellable<T: Sendable>(_ body: @escaping @Sendable (CancelToken) throws -> T) async throws -> T {
    let token = CancelToken()
    return try await withTaskCancellationHandler {
        try await blocking { try body(token) }
    } onCancel: { token.cancel() }
}

/// The app's value as the text Core reads. A Swift `JSON` cannot hold `undefined`. A non-finite
/// number has no JSON form: it is written as its bare token (`NaN`, `Infinity`, `-Infinity`), so
/// the text is not JSON and Core refuses it with its own code and category (Leo 18:40Z). Never
/// dropped, and no code or category is chosen here.
func text(_ value: JSON) -> String {
    let mark = "croche-nonfinite-\(UUID().uuidString)"
    let encoder = JSONEncoder()
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: mark + "+", negativeInfinity: mark + "-", nan: mark + "n")
    // JSON's cases are strings, numbers, bools, null, arrays and objects: encoding cannot otherwise fail.
    let encoded = String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self)
    guard encoded.contains(mark) else { return encoded }
    return encoded.replacingOccurrences(of: "\"\(mark)+\"", with: "Infinity")
        .replacingOccurrences(of: "\"\(mark)-\"", with: "-Infinity")
        .replacingOccurrences(of: "\"\(mark)n\"", with: "NaN")
}

/// A completion fact's JSON text, or nil when it has none (the caller sends its fallback fact).
func strictText(_ value: JSON) -> String? {
    (try? value.encoded()).map { String(decoding: $0, as: UTF8.self) }
}

/// A Core reply. Unreadable = a Core bug, reported as such.
func reply(_ text: String) throws -> JSON {
    do { return try JSON(text) } catch { throw CrocheError(code: "internal", message: "Core's reply is not JSON.", category: .internal) }
}
