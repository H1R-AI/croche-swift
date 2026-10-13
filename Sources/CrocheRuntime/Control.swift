import Foundation

public typealias ControlSend = @Sendable (_ input: JSON, _ cancellation: RuntimeCancellation) async throws -> JSON
public typealias ControlCancel = @Sendable () async -> Bool

/// Opt-in attachment of an existing Runtime. This broker token is unrelated to Cloud
/// developer/project credentials. No Runtime identity or storage is opened here.
public actor RuntimeControl {
    public nonisolated let runtimeInstanceId: String
    public nonisolated let capabilities = ["status", "history", "send", "cancel", "sync", "budget.get", "budget.set", "tools"]
    private let runtime: CrocheRuntime
    private let url: String
    private let token: String
    private let clientId = UUID().uuidString
    private let http: RuntimeHTTP
    private let sendAdapter: ControlSend?
    private let cancelAdapter: ControlCancel?
    private let onError: (@Sendable (CrocheError) -> Void)?
    private let lifetime = RuntimeCancellation()
    private var loop: Task<Void, Never>?
    private var closed = false
    private var handled = Set<String>()
    private var results: [String: JSON] = [:]
    private var active: [String: RuntimeCancellation] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private init(runtime: CrocheRuntime, runtimeInstanceId: String, url: String, token: String,
                 http: @escaping RuntimeHTTP, send: ControlSend?, cancel: ControlCancel?,
                 onError: (@Sendable (CrocheError) -> Void)?) {
        self.runtime = runtime; self.runtimeInstanceId = runtimeInstanceId; self.url = url; self.token = token
        self.http = http; sendAdapter = send; cancelAdapter = cancel; self.onError = onError
    }
    public static func attach(runtime: CrocheRuntime, url: String = "http://127.0.0.1:8791", token: String,
                              http: @escaping RuntimeHTTP = { try await RuntimeURLSession.send($0, cancellation: $1, onDelta: $2) },
                              send: ControlSend? = nil, cancel: ControlCancel? = nil,
                              onError: (@Sendable (CrocheError) -> Void)? = nil) async throws -> RuntimeControl {
        guard let parsed = URLComponents(string: url), parsed.scheme == "http",
              ["localhost", "127.0.0.1", "[::1]", "::1"].contains(parsed.host ?? ""),
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil,
              parsed.path.isEmpty || parsed.path == "/",
              token.range(of: "^[A-Za-z0-9._~-]{24,4096}$", options: .regularExpression) != nil else {
            throw CrocheError("invalid_configuration", "Control requires a loopback HTTP origin and explicit local token")
        }
        let status = try await runtime.inspect()["status"]
        let id = status["runtimeInstanceId"].string ?? ""
        guard validControlId(id) else { throw CrocheError("invalid_configuration", "Invalid Runtime identity") }
        let control = RuntimeControl(runtime: runtime, runtimeInstanceId: id,
                                     url: url.hasSuffix("/") ? String(url.dropLast()) : url, token: token,
                                     http: http, send: send, cancel: cancel, onError: onError)
        try await control.start(status)
        return control
    }
    private var identity: [String: JSON] { ["client_id": .string(clientId), "runtime_instance_id": .string(runtimeInstanceId)] }
    private func register(_ status: JSON) async throws {
        _ = try await post("register", .object(["client_id": .string(clientId), "runtime": status,
                                                "capabilities": .array(capabilities.map(JSON.string))]))
    }
    private func start(_ status: JSON) async throws {
        try await register(status)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let keep = await self?.tick(), keep else { break }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
            }
        }
    }
    private func post(_ path: String, _ body: JSON) async throws -> JSON {
        guard try body.encoded().count <= 1024 * 1024 else { throw CrocheError("control_capacity", "Control request exceeds 1MiB") }
        let effect = JSON.object(["url": .string(url + "/v1/control/" + path), "method": .string("POST"),
                                  "headers": .object(["Authorization": .string("Bearer " + token), "Content-Type": .string("application/json")]),
                                  "body": body, "timeoutMs": .number(5000)])
        let transport = http
        let response = try await boundedEffect(milliseconds: 5000, cancellation: lifetime) { signal in try await transport(effect, signal) { _ in } }
        let data = response["body"]
        guard data.object != nil, try data.encoded().count <= 1024 * 1024 else { throw CrocheError("invalid_response", "Invalid bounded control response") }
        guard let status = response["status"].number, (200..<300).contains(status) else {
            throw CrocheError(data["error"]["code"].string ?? "control_error", "Local control broker rejected the request")
        }
        return data
    }
    private func tick() async -> Bool {
        if closed { return false }
        do {
            for (id, result) in Array(results.prefix(8)) {
                do { _ = try await post("results", result); results.removeValue(forKey: id) }
                catch let error as CrocheError {
                    if ["not_found", "attachment_lost"].contains(error.code) { results.removeValue(forKey: id) }
                    throw error
                }
            }
            if results.count < 32 && tasks.count < 16 {
                let response = try await post("poll", .object(identity))
                guard let commands = response["commands"].array else { throw CrocheError("invalid_response", "Broker command list is invalid") }
                for command in commands.prefix(8) { try accept(command) }
            }
        } catch {
            if !closed {
                let issue = error as? CrocheError ?? CrocheError("control_error", "Local control failed")
                onError?(issue)
                if issue.code == "attachment_lost" {
                    do { try await register(runtime.inspect()["status"]) } catch {}
                }
            }
        }
        return !closed
    }
    private func accept(_ value: JSON) throws {
        let id = value["request_id"].string ?? "", command = value["command"].string ?? ""
        guard validControlId(id), capabilities.contains(command), let payload = value["payload"].object else {
            throw CrocheError("invalid_command", "Invalid control command envelope")
        }
        if handled.contains(id) { return }
        guard handled.count < 1000 else { throw CrocheError("control_capacity", "Reattach after 1000 control requests") }
        handled.insert(id)
        tasks[id] = Task { await self.perform(id, command, .object(payload)) }
    }
    private func perform(_ id: String, _ command: String, _ payload: JSON) async {
        var response = identity; response["request_id"] = .string(id)
        do {
            let result = try await execute(command, payload, id)
            guard try result.encoded().count <= 900_000 else { throw CrocheError("result_too_large", "Request a smaller result page") }
            response["result"] = result
        } catch {
            response["error"] = .object(["code": .string(publicControlCode(error)),
                                          "message": .string("The Runtime command failed. Inspect it before retrying."),
                                          "uncertain": .bool(command == "send" || command == "budget.set")])
        }
        if !closed { results[id] = .object(response) }
        tasks.removeValue(forKey: id)
    }
    private func execute(_ command: String, _ payload: JSON, _ id: String) async throws -> JSON {
        guard !closed else { throw CrocheError("control_closed", "Control is closed") }
        let keys = Set(payload.object!.keys)
        if command == "send" {
            guard keys.isSubset(of: ["id", "text"]), validControlId(payload["id"].string ?? ""),
                  let text = payload["text"].string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf16.count <= 32000 else { throw CrocheError("invalid_command", "send needs immutable id and text only") }
            let signal = RuntimeCancellation(); active[id] = signal; defer { active.removeValue(forKey: id) }
            if let sendAdapter { return try await sendAdapter(payload, signal) }
            let task = Task { try await runtime.send(payload) }
            let listener = signal.observe { task.cancel() }; defer { signal.remove(listener) }
            return try await task.value
        }
        if command == "history" {
            guard keys.isSubset(of: ["offset", "limit"]) else { throw CrocheError("invalid_command", "Unsupported history fields") }
            guard (!keys.contains("offset") || payload["offset"].number != nil), (!keys.contains("limit") || payload["limit"].number != nil) else { throw CrocheError("invalid_command", "History page values must be numbers") }
            let offset = payload["offset"].number ?? 0, limit = payload["limit"].number ?? 100
            guard offset.isFinite, offset >= 0, offset <= Double(Int.max / 2), offset.rounded() == offset,
                  limit >= 1, limit <= 200, limit.rounded() == limit else { throw CrocheError("invalid_command", "Invalid history page") }
            let history = try await runtime.inspect()["history"].array ?? []
            return .object(["messages": .array(Array(history.dropFirst(Int(offset)).prefix(Int(limit)))),
                            "total": .number(Double(history.count)), "offset": .number(offset), "limit": .number(limit)])
        }
        if command == "budget.set" {
            guard keys == ["amount"], let amount = payload["amount"].number, amount.isFinite, amount >= 0 else {
                throw CrocheError("invalid_command", "Budget needs a non-negative finite amount")
            }
            return try await runtime.adjustBudget(amount, absolute: true)
        }
        guard keys.isEmpty else { throw CrocheError("invalid_command", "Unsupported command fields") }
        if command == "cancel" {
            let hadActive = !active.isEmpty; for signal in active.values { signal.cancel() }
            let host = await cancelAdapter?() ?? false
            return .object(["requested": .bool(hadActive || host), "scope": .string(cancelAdapter == nil ? "control_client" : "host"), "rollback": .bool(false)])
        }
        if command == "sync" { _ = try await runtime.sync() }
        let view = try await runtime.inspect()
        switch command {
        case "status":
            var status = view["status"]; status["control"] = .object(["cancellation_scope": .string(cancelAdapter == nil ? "control_client" : "host")]); return status
        case "sync": return view["status"]
        case "tools": return view["tools"]
        case "budget.get": return view["budget"]
        default: throw CrocheError("unsupported_capability", "Unsupported Runtime command")
        }
    }
    public func close() async {
        if closed { return }; closed = true
        for signal in active.values { signal.cancel() }
        // Transport stays alive for unregister; closing attachment never closes Runtime.
        _ = try? await post("unregister", .object(identity))
        lifetime.cancel(); loop?.cancel(); await loop?.value; loop = nil
    }
}
private func validControlId(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9_.:-]{1,200}$", options: .regularExpression) != nil
}

private func publicControlCode(_ error: Error) -> String {
    let code = (error as? CrocheError)?.code ?? "runtime_error"
    return ["invalid_command", "control_closed", "unsupported_capability", "result_too_large", "busy", "closed", "storage_error", "context_limit", "budget_limit"].contains(code) ? code : "runtime_error"
}
