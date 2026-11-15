import Foundation
import CrocheFFI

/// What the model asked for. Bound arguments are already merged in by Core.
public struct ToolCall: Sendable {
    public let key: String
    public let args: [String: JSON]
}

/// Who the call works for. Cancellation is the Task's: it fires on cancel, agent close and teardown.
public struct ToolContext: Sendable {
    public let callId: String
    public let agentId: String
    /// nil = the default instance.
    public let instance: String?
    public let user: String?
    /// The input ids this call works for (avoid buying twice).
    public let causedBy: [String]
}

public enum ToolContent: Sendable, Equatable {
    case text(String)
    /// Base64 bytes.
    case image(mediaType: String, data: String)
    /// A `file://` URL, read by the native PAL.
    case imageFile(mediaType: String, uri: String)
}

/// A tool's tagged result. Returning nil is the empty result.
public enum ToolResult: Sendable, Equatable {
    case content([ToolContent])
    case json(JSON)
}

/// Its message reaches the model verbatim. Core chooses every code.
public struct ToolError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public typealias ToolExecute = @Sendable (ToolCall, ToolContext) async throws -> ToolResult?

/// A manifest (JSON, the same on every SDK) plus its execute. Core validates the manifest
/// here: an invalid one throws `invalid_tool` with Core's path.
public final class ToolDefinition: Sendable {
    let core: CoreToolDefinition
    public var name: String { core.name() }
    init(core: CoreToolDefinition) { self.core = core }
    init(manifest: JSON, execute: @escaping ToolExecute) throws {
        let text = text(manifest)
        do { core = try CoreToolDefinition(manifestJson: text, execute: ToolExecuteAdapter(execute)) }
        catch { throw CrocheError(error) }
    }
}

public func defineTool(_ manifest: JSON, _ execute: @escaping ToolExecute) throws -> ToolDefinition {
    try ToolDefinition(manifest: manifest, execute: execute)
}

/// The same, for a handler that returns a plain Swift value (Leo 17:23Z): String, a number,
/// Bool, nil, a Dictionary or Array of those, or any `Encodable`. It is serialized to JSON
/// mechanically (no policy); a `ToolResult` passes through and nil is "nothing to report", as
/// for `ToolExecute`. A value that has no JSON form (a non-finite number, a non-string key, a
/// class instance) reaches Core as `invalid_result`; Core chooses the code.
public func defineTool(_ manifest: JSON, _ execute: @escaping @Sendable (ToolCall, ToolContext) async throws -> (any Sendable)?) throws -> ToolDefinition {
    try ToolDefinition(manifest: manifest, execute: PlainToolValue.execute(execute))
}

/// Mechanical Swift value -> JSON for tool returns. Serialization only.
enum PlainToolValue {
    /// The value had no JSON form: the adapter reports `invalid_result`.
    struct Unconvertible: Error, CustomStringConvertible {
        let reason: String
        var description: String { "The tool's return value has no JSON form: \(reason)" }
    }

    /// The plain handler as a `ToolExecute`: a `ToolResult` passes through, nil is nothing to report.
    static func execute(_ plain: @escaping @Sendable (ToolCall, ToolContext) async throws -> (any Sendable)?) -> ToolExecute {
        { call, context in
            guard let value = try await plain(call, context) else { return nil }
            if let result = value as? ToolResult { return result }
            let json = try json(value)
            return json == .null ? nil : .json(json)
        }
    }

    static func json(_ value: Any) throws -> JSON {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional { return try mirror.children.first.map { try json($0.value) } ?? .null }
        if value is NSNull { return .null }
        switch value {
        case let value as JSON: return value
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as Int: return try number(Double(exactly: value), "\(value)")
        case let value as Int8: return .number(Double(value))
        case let value as Int16: return .number(Double(value))
        case let value as Int32: return .number(Double(value))
        case let value as Int64: return try number(Double(exactly: value), "\(value)")
        case let value as UInt: return try number(Double(exactly: value), "\(value)")
        case let value as UInt8: return .number(Double(value))
        case let value as UInt16: return .number(Double(value))
        case let value as UInt32: return .number(Double(value))
        case let value as UInt64: return try number(Double(exactly: value), "\(value)")
        // A non-finite number has no JSON text: the adapter's encoding fallback sends invalid_result.
        case let value as Double: return .number(value)
        case let value as Float: return .number(Double(value))
        case let value as [String: Any]: return .object(try value.mapValues { try json($0) })
        case let value as [Any]: return .array(try value.map { try json($0) })
        case let value as any Encodable:
            do { return try JSON(data: JSONEncoder().encode(value)) }
            catch { throw Unconvertible(reason: "\(type(of: value)) did not encode: \(error)") }
        default: throw Unconvertible(reason: "\(type(of: value)) is not String, a number, Bool, nil, a Dictionary or Array of those, or Encodable")
        }
    }

    private static func number(_ value: Double?, _ text: String) throws -> JSON {
        guard let value else { throw Unconvertible(reason: "\(text) is not a number JSON can carry exactly") }
        return .number(value)
    }
}

/// `Croche.open` registration: a tool, or a tool with a bind for every agent. No commands or guide here.
public enum ToolRegistration: Sendable {
    case tool(ToolDefinition)
    /// `[:]` is an explicit empty bind and reaches Core as `{}`, distinct from `.tool`.
    case bound(ToolDefinition, bind: [String: JSON])

    /// The entry as the app wrote it, with only the opaque tool replaced by null (Atlas's S1
    /// ABI): a bare tool = null; a wrapper keeps every key. Core validates, never this layer.
    var json: JSON {
        switch self {
        case .tool: .null
        case .bound(_, let bind): .object(["tool": .null, "bind": .object(bind)])
        }
    }

    func core() throws -> CoreToolRegistration {
        switch self {
        case .tool(let tool): CoreToolRegistration(tool: tool.core, optionsJson: nil)
        case .bound(let tool, _): CoreToolRegistration(tool: tool.core, optionsJson: text(json))
        }
    }
}

/// Core-owned tools. Registered name `webSearch`.
public enum CrocheTools {
    public static var webSearch: ToolDefinition { ToolDefinition(core: coreWebSearch()) }
}

/// Core's execute callback, on a Core worker thread. Reports one tagged fact; Core applies policy
/// (tool_failed, cancelled, timeouts): empty | json | result | tool_error | handler_error | cancelled |
/// unavailable | invalid_result, discriminated by `type` (Atlas's pin, 10-30).
final class ToolExecuteAdapter: CoreToolExecute, @unchecked Sendable {
    private let execute: ToolExecute
    init(_ execute: @escaping ToolExecute) { self.execute = execute }

    func execute(callJson: String, contextJson: String, cancel: CancelToken) throws -> String {
        let call = try JSON(callJson), context = try JSON(contextJson)
        let toolCall = ToolCall(key: call["key"].string ?? "", args: call["args"].object ?? [:])
        let toolContext = ToolContext(callId: context["callId"].string ?? "", agentId: context["agentId"].string ?? "", instance: context["instance"].string,
                                         user: context["user"].string, causedBy: context["causedBy"].array?.compactMap(\.string) ?? [])
        let execute = self.execute
        let box = ResultBox<ToolResult?>()
        let done = DispatchSemaphore(value: 0)
        let task = appTask {
            do { box.set(.success(try await execute(toolCall, toolContext))) } catch { box.set(.failure(error)) }
            done.signal()
        }
        cancel.onCancel(callback: TaskCancel(task))
        done.wait()
        // A result JSON cannot carry (a non-finite number) is a transport fact; Core picks the code.
        return (strictText(Self.completion(box, cancelled: cancel.isCancelled()))) ?? #"{"type":"invalid_result"}"#
    }

    static func completion(_ box: ResultBox<ToolResult?>, cancelled: Bool) -> JSON {
        do {
            switch try box.get() {
            case nil: return .object(["type": .string("empty")])
            case .json(let value)?: return .object(["type": .string("json"), "value": value])
            case .content(let content)?: return .object(["type": .string("result"), "content": .array(content.map(\.json))])
            }
        } catch is PlainToolValue.Unconvertible {
            return .object(["type": .string("invalid_result")])
        } catch let error as ToolError {
            return .object(["type": .string("tool_error"), "message": .string(error.message)])
        } catch {
            if error is CancellationError || cancelled { return .object(["type": .string("cancelled")]) }
            // The throw passes unchanged; Core applies tool_failed and maps no code here.
            return .object(["type": .string("handler_error"),
                             "error": .object(["type": .string(String(reflecting: type(of: error))), "message": .string("\(error)")])])
        }
    }
}

private final class TaskCancel: CancelCallback, @unchecked Sendable {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancelled() { task.cancel() }
}

extension ToolContent {
    var json: JSON {
        switch self {
        case .text(let text): .object(["type": .string("text"), "text": .string(text)])
        case .image(let mediaType, let data): .object(["type": .string("image"), "mediaType": .string(mediaType), "data": .string(data)])
        case .imageFile(let mediaType, let uri): .object(["type": .string("image"), "mediaType": .string(mediaType), "uri": .string(uri)])
        }
    }
}
