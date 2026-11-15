import Foundation
import CrocheFFI
#if canImport(Network)
import Network
import Security

/// One direct HTTP/1.1 exchange to Core's pinned address (parity with Android's DirectHttpPal):
/// Network.framework to `connectTo`, TLS server name AND peer verification = the URL host, ALPN
/// http/1.1 only, no redirects, proxy, pool, cookies or cache. Core supplies policy and the
/// deadline; this supplies bytes. Shared cases: vectors/http-pal-direct.json.
final class DirectHTTP: @unchecked Sendable {
    /// Test anchors only (the vector harness's throwaway certificate); nil = the system trust store.
    private let anchors: [SecCertificate]?
    init(anchors: [SecCertificate]? = nil) { self.anchors = anchors }

    private static let lineLimit = 8192, headLimit = 65536, interimLimit = 16

    func http(_ request: PalHttpRequest, pin: String, sink: any HttpSinkProtocol, cancel: CancelToken) throws {
        guard let url = URLComponents(string: request.url), let rawHost = url.host, !rawHost.isEmpty,
              let scheme = url.scheme, scheme == "https" || scheme == "http" else { throw LegacyCrocheError("invalid_abi", "Invalid HTTP URL") }
        guard url.user == nil, url.password == nil else { throw LegacyCrocheError("invalid_abi", "HTTP user info is unsupported") }
        let host = rawHost.hasPrefix("[") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let address = try Self.numeric(pin)
        let tls = scheme == "https"
        let port = url.port ?? (tls ? 443 : 80)
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw LegacyCrocheError("invalid_abi", "Invalid HTTP port") }
        let head = try Self.requestHead(request, url: url)
        if cancel.isCancelled() { throw LegacyCrocheError("cancelled", "The request was cancelled.") }

        let connection = NWConnection(host: address, port: endpointPort, using: parameters(tls: tls, host: host))
        let wire = Wire(connection)
        cancel.onCancel(callback: Closer(wire, reason: "cancelled"))
        let deadline = DispatchWorkItem { wire.close(reason: "deadline") }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(clamping: max(1, request.timeoutMs))), execute: deadline)
        defer { deadline.cancel(); wire.close(reason: nil) }
        do {
            try wire.start()
            try wire.send(head + Data((request.body ?? "").utf8))
            try Self.readResponse(wire, request, sink, cancel)
        } catch {
            if cancel.isCancelled() { throw LegacyCrocheError("cancelled", "The request was cancelled.") }
            if let error = error as? LegacyCrocheError, error.code != "network_error" { throw error }
            throw LegacyCrocheError("network_error", "HTTP transport failed")
        }
    }

    private func parameters(tls: Bool, host: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        guard tls else { let p = NWParameters(tls: nil, tcp: tcp); p.preferNoProxies = true; return p }
        let options = NWProtocolTLS.Options(), sec = options.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(sec, host)
        sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
        let anchors = self.anchors
        // The name verified is the URL host, never the pinned address.
        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            if let anchors { SecTrustSetAnchorCertificates(trust, anchors as CFArray); SecTrustSetAnchorCertificatesOnly(trust, true) }
            complete(SecTrustEvaluateWithError(trust, nil))
        }, DispatchQueue.global())
        let p = NWParameters(tls: options, tcp: tcp); p.preferNoProxies = true
        return p
    }

    /// A malformed pin never reaches a resolver or an unpinned fallback.
    static func numeric(_ pin: String) throws -> NWEndpoint.Host {
        if let v4 = IPv4Address(pin), pin.split(separator: ".").count == 4, pin.allSatisfy({ $0.isNumber || $0 == "." }) { return .ipv4(v4) }
        if pin.contains(":"), pin.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }), let v6 = IPv6Address(pin) { return .ipv6(v6) }
        throw LegacyCrocheError("invalid_abi", "Invalid HTTP connectTo")
    }

    static func requestHead(_ request: PalHttpRequest, url: URLComponents) throws -> Data {
        let target = (url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath) + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        let authority = (url.percentEncodedHost ?? "") + (url.port.map { ":\($0)" } ?? "")
        func line(_ value: String) throws -> String {
            // Bytes, not Characters: "\r\n" is one grapheme, so contains("\r") would miss it.
            guard !value.utf8.contains(13), !value.utf8.contains(10) else { throw LegacyCrocheError("invalid_abi", "Invalid HTTP request line") }
            return value
        }
        var text = "\(try line(request.method)) \(try line(target)) HTTP/1.1\r\nHost: \(authority)\r\nConnection: close\r\n"
        for header in request.headers where !["host", "connection", "content-length", "transfer-encoding"].contains(header.name.lowercased()) {
            text += "\(try line(header.name)): \(try line(header.value))\r\n"
        }
        if let body = request.body { text += "Content-Length: \(body.utf8.count)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    private static func bad(_ what: String) -> LegacyCrocheError { LegacyCrocheError("network_error", what) }

    static func readResponse(_ wire: Wire, _ request: PalHttpRequest, _ sink: any HttpSinkProtocol, _ cancel: CancelToken) throws {
        var status = 0, headers: [PalHeader] = [], interims = 0
        repeat {
            let statusLine = try wire.line(limit: lineLimit)
            let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard statusLine.hasPrefix("HTTP/1."), parts.count >= 2, let code = Int(parts[1]), (100...599).contains(code) else { throw bad("Invalid HTTP status") }
            status = code; headers = []
            var bytes = statusLine.utf8.count
            while true {
                let field = try wire.line(limit: lineLimit)
                bytes += field.utf8.count + 2
                guard bytes <= headLimit else { throw bad("HTTP headers exceed bound") }
                if field.isEmpty { break }
                guard let colon = field.firstIndex(of: ":"), colon != field.startIndex, !(field.first?.isWhitespace ?? true) else { throw bad("Invalid HTTP header") }
                headers.append(PalHeader(name: String(field[..<colon]), value: field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
            interims += 1
            guard interims <= interimLimit else { throw bad("Too many interim responses") }
        } while (100...199).contains(status) && status != 101
        sink.head(status: UInt16(status), headers: headers)
        if request.method == "HEAD" || (100...199).contains(status) || status == 204 || status == 304 { return }
        let lengths = Set(headers.filter { $0.name.lowercased() == "content-length" }.map(\.value))
        guard lengths.count <= 1 else { throw bad("Conflicting HTTP lengths") }
        let codings = headers.filter { $0.name.lowercased() == "transfer-encoding" }.map { $0.value.lowercased() }
        guard codings.isEmpty || codings == ["chunked"] else { throw bad("Unsupported HTTP transfer coding") }
        var received: UInt64 = 0
        /// false = the sink wants no more.
        func copy(_ count: Int?) throws -> Bool {
            var remaining = count
            while remaining.map({ $0 > 0 }) ?? true {
                if cancel.isCancelled() { throw LegacyCrocheError("cancelled", "The request was cancelled.") }
                guard let piece = try wire.read(max: min(remaining ?? 65536, 65536)) else {
                    if remaining != nil { throw bad("HTTP body ended early") }
                    return true
                }
                received += UInt64(piece.count)
                guard received <= request.maxResponseBytes else { throw LegacyCrocheError("invalid_response", "HTTP response exceeds bound") }
                if !sink.chunk(bytes: piece) { return false }
                remaining = remaining.map { $0 - piece.count }
            }
            return true
        }
        if !codings.isEmpty {
            while true {
                let sizeLine = try wire.line(limit: lineLimit)
                let digits = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit), let size = Int(digits, radix: 16) else { throw bad("Invalid HTTP chunk") }
                if size == 0 {
                    var trailerBytes = 0
                    while true {
                        let trailer = try wire.line(limit: lineLimit)
                        trailerBytes += trailer.utf8.count + 2
                        guard trailerBytes <= headLimit else { throw bad("HTTP trailers exceed bound") }
                        if trailer.isEmpty { return }
                    }
                }
                if try !copy(size) { return }
                guard try wire.line(limit: lineLimit).isEmpty else { throw bad("Invalid chunk terminator") }
            }
        }
        if let text = lengths.first {
            guard text.allSatisfy(\.isNumber), let length = Int(text) else { throw bad("Invalid HTTP length") }
            _ = try copy(length)
        } else { _ = try copy(nil) }
    }
}

/// A blocking view of one connection for the PAL's worker thread: start, send, and buffered reads.
final class Wire: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ai.croche.direct-http")
    private var buffer = Data()
    private var ended = false
    private let lock = NSLock()
    private var closedReason: String?
    init(_ connection: NWConnection) { self.connection = connection }

    func close(reason: String?) {
        lock.withLock { if closedReason == nil { closedReason = reason ?? "closed" } }
        connection.cancel()
    }
    private func failIfClosed() throws {
        if let reason = lock.withLock({ closedReason }) { throw LegacyCrocheError(reason == "cancelled" ? "cancelled" : "network_error", "HTTP transport \(reason)") }
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let outcome = Box<Bool>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: outcome.once(true) { ready.signal() }
            case .failed, .cancelled, .waiting: outcome.once(false) { ready.signal() }
            default: break
            }
        }
        connection.start(queue: queue)
        ready.wait()
        try failIfClosed()
        guard outcome.value == true else { throw LegacyCrocheError("network_error", "HTTP connection failed") }
    }

    func send(_ data: Data) throws {
        let done = DispatchSemaphore(value: 0), failed = Box<Bool>()
        connection.send(content: data, completion: .contentProcessed { error in failed.once(error != nil) { done.signal() } })
        done.wait()
        try failIfClosed()
        if failed.value == true { throw LegacyCrocheError("network_error", "HTTP send failed") }
    }

    /// Fills the buffer once. false = the peer ended the stream.
    private func fill() throws -> Bool {
        if ended { return false }
        let done = DispatchSemaphore(value: 0)
        let result = Box<(Data?, Bool, Bool)>()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            result.once((data, complete, error != nil)) { done.signal() }
        }
        done.wait()
        try failIfClosed()
        guard let (data, complete, failed) = result.value, !failed else { throw LegacyCrocheError("network_error", "HTTP receive failed") }
        if let data { buffer.append(data) }
        if complete { ended = true }
        return !(data?.isEmpty ?? true) || !complete
    }

    /// One CRLF-terminated line, without it. A bare LF, an over-long line or EOF fails.
    func line(limit: Int) throws -> String {
        while true {
            if let cr = buffer.firstIndex(of: 13) {
                guard cr - buffer.startIndex <= limit else { throw LegacyCrocheError("network_error", "HTTP line exceeds bound") }
                guard buffer.index(after: cr) < buffer.endIndex else { if try !fill() { throw LegacyCrocheError("network_error", "HTTP stream ended") }; continue }
                guard buffer[buffer.index(after: cr)] == 10 else { throw LegacyCrocheError("network_error", "Invalid HTTP line ending") }
                if buffer[buffer.startIndex..<cr].contains(10) { throw LegacyCrocheError("network_error", "Invalid HTTP line ending") }
                let text = String(decoding: buffer[buffer.startIndex..<cr], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...buffer.index(after: cr))
                return text
            }
            if buffer.contains(10) { throw LegacyCrocheError("network_error", "Invalid HTTP line ending") }
            guard buffer.count <= limit else { throw LegacyCrocheError("network_error", "HTTP line exceeds bound") }
            if try !fill() { throw LegacyCrocheError("network_error", "HTTP stream ended") }
        }
    }

    /// Up to `max` bytes; nil at the end of the stream.
    func read(max: Int) throws -> Data? {
        if buffer.isEmpty, try !fill(), buffer.isEmpty { return nil }
        if buffer.isEmpty { return try read(max: max) }
        let piece = buffer.prefix(max)
        buffer.removeFirst(piece.count)
        return Data(piece)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func once(_ value: T, _ then: () -> Void) {
        let first = lock.withLock { () -> Bool in guard stored == nil else { return false }; stored = value; return true }
        if first { then() }
    }
}

private final class Closer: CancelCallback, @unchecked Sendable {
    private weak var wire: Wire?
    private let reason: String
    init(_ wire: Wire, reason: String) { self.wire = wire; self.reason = reason }
    func cancelled() { wire?.close(reason: reason) }
}
#endif
