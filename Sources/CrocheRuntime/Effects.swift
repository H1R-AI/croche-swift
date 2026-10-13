import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cooperative tool cancellation. A cancelled invocation is never automatically replayed.
public final class RuntimeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var listeners: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.withLock { stopped } }
    public func check() throws {
        if isCancelled { throw CrocheError("cancelled", "The operation was cancelled") }
    }
    public func cancel() {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            guard !stopped else { return [] }; stopped = true
            let values = Array(listeners.values); listeners.removeAll(); return values
        }
        for callback in callbacks { callback() }
    }
    @discardableResult func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let already = lock.withLock { if stopped { return true }; listeners[id] = callback; return false }
        if already { callback() }; return id
    }
    func remove(_ id: UUID) { _ = lock.withLock { listeners.removeValue(forKey: id) } }
}

private final class EffectRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var done = false
    private var tasks: [Task<Void, Never>] = []
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func add(_ task: Task<Void, Never>) {
        if lock.withLock({ if done { return true }; tasks.append(task); return false }) { task.cancel() }
    }
    func finish(_ result: Result<T, Error>) {
        let pending = lock.withLock { () -> (CheckedContinuation<T, Error>?, [Task<Void, Never>]) in
            guard !done else { return (nil, []) }; done = true
            let c = continuation; continuation = nil; let t = tasks; tasks = []; return (c, t)
        }
        pending.0?.resume(with: result)
        for task in pending.1 { task.cancel() }
    }
}

func boundedEffect(milliseconds: Double, cancellation: RuntimeCancellation,
                   body: @escaping @Sendable (RuntimeCancellation) async throws -> JSON) async throws -> JSON {
    try await bounded(milliseconds: milliseconds, cancellation: cancellation, body: body)
}

/// A deadline returns even when an application handler ignores cancellation. Its context
/// is revoked and any late result is discarded; the host cannot promise effect rollback.
/// `milliseconds` nil: no deadline here, only `cancellation` (a tool: the Runtime is its only
/// clock and cancels it at the command's deadline).
func bounded<T: Sendable>(milliseconds: Double?, cancellation: RuntimeCancellation,
                   body: @escaping @Sendable (RuntimeCancellation) async throws -> T) async throws -> T {
    let local = RuntimeCancellation()
    return try await withCheckedThrowingContinuation { continuation in
        let race = EffectRace<T>(continuation)
        let listener = cancellation.observe {
            local.cancel(); race.finish(.failure(CrocheError("cancelled", "The operation was cancelled")))
        }
        race.add(Task {
            do { try local.check(); let value = try await body(local); try local.check(); race.finish(.success(value)) }
            catch { race.finish(.failure(error)) }
            cancellation.remove(listener)
        })
        guard let milliseconds else { return }
        race.add(Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(1, milliseconds) * 1_000_000))
                race.finish(.failure(CrocheError("timeout", "The effect deadline expired"))); local.cancel()
                cancellation.remove(listener)
            } catch {}
        })
    }
}

/// `onDelta` receives each server-sent event's data while a streamed response arrives, in
/// order; the Rust Core assembles them. A transport that cannot stream never calls it.
public typealias RuntimeHTTP = @Sendable (_ effect: JSON, _ cancellation: RuntimeCancellation,
                                          _ onDelta: @escaping @Sendable (String) async -> Void) async throws -> JSON

private let maxResponseBytes = 2 * 1024 * 1024
/// A gateway stream wraps each piece of content in its own JSON event.
private let maxStreamBytes = 3 * maxResponseBytes

/// Ephemeral URLSession transport: no cookies/cache, no redirects, 2MiB response bound.
/// A `text/event-stream` answer is read incrementally and its deltas are handed on.
public enum RuntimeURLSession {
    public static func send(_ effect: JSON, cancellation: RuntimeCancellation,
                            onDelta: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> JSON {
        try cancellation.check()
        guard let address = effect["url"].string, let url = URL(string: address) else {
            throw CrocheError("network_error", "Invalid HTTP effect URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = effect["method"].string
        if !["GET", "HEAD"].contains(request.httpMethod ?? "") { request.httpBody = try effect["body"].encoded() }
        request.timeoutInterval = (effect["timeoutMs"].number ?? 30_000) / 1000
        request.httpShouldHandleCookies = false
        for (name, value) in effect["headers"].object ?? [:] {
            if let value = value.string { request.setValue(value, forHTTPHeaderField: name) }
        }
        let (chunks, sink) = AsyncThrowingStream<HTTPPart, Error>.makeStream()
        let delegate = HTTPDelegate(sink)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        let listener = cancellation.observe { task.cancel() }
        defer { cancellation.remove(listener) }
        task.resume()
        return try await read(chunks, cancellation: cancellation, onDelta: onDelta)
    }

    static func read(_ chunks: AsyncThrowingStream<HTTPPart, Error>, cancellation: RuntimeCancellation,
                     onDelta: @Sendable (String) async -> Void) async throws -> JSON {
        var status = 0
        var headers: [String: JSON] = [:]
        var streaming = false
        var body = Data()
        var parser = EventStreamParser()
        var size = 0
        for try await part in chunks {
            switch part {
            case .head(let code, let fields, let expected):
                status = code; headers = fields
                let type = fields.first { $0.key.lowercased() == "content-type" }?.value.string ?? ""
                // A refusal arrives as ordinary JSON even when a stream was asked for; only an
                // event stream is read incrementally.
                streaming = (200..<300).contains(code) && type.lowercased().hasPrefix("text/event-stream")
                if !streaming && expected > Int64(maxResponseBytes) {
                    throw CrocheError("invalid_response", "HTTP response exceeds 2MiB")
                }
            case .body(let data):
                size += data.count
                if !streaming {
                    guard size <= maxResponseBytes else { throw CrocheError("invalid_response", "HTTP response exceeds 2MiB") }
                    body.append(data); continue
                }
                guard size <= maxStreamBytes else { throw CrocheError("invalid_provider_response", "The gateway stream exceeds its bound") }
                for event in parser.push([UInt8](data)) where !event.data.isEmpty { await onDelta(event.data) }
            }
        }
        try cancellation.check()
        if streaming {
            for event in parser.end() where !event.data.isEmpty { await onDelta(event.data) }
            // The stream's end completes the call; the Core judges what it assembled.
            return .object(["status": .number(Double(status)), "headers": .object(headers), "streamed": .bool(true)])
        }
        var reply = JSON.object(["status": .number(Double(status)), "headers": .object(headers)])
        if let parsed = try? JSON(data: body) { reply["body"] = parsed }
        else { reply["raw"] = .string(String(decoding: body, as: UTF8.self)) }
        return reply
    }
}

enum HTTPPart: Sendable {
    case head(status: Int, headers: [String: JSON], expectedLength: Int64)
    case body(Data)
}

private final class HTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sink: AsyncThrowingStream<HTTPPart, Error>.Continuation
    init(_ sink: AsyncThrowingStream<HTTPPart, Error>.Continuation) { self.sink = sink }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            sink.finish(throwing: CrocheError("network_error", "No HTTP response")); completionHandler(.cancel); return
        }
        var headers: [String: JSON] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key)] = .string(String(describing: value)) }
        sink.yield(.head(status: http.statusCode, headers: headers, expectedLength: response.expectedContentLength))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        sink.yield(.body(chunk))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { sink.finish(throwing: CrocheError("network_error", "HTTP transport failed")) }
        else { sink.finish() }
    }
}
