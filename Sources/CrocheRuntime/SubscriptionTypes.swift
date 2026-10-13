import Foundation

public enum ImageResolution: String, Sendable, Codable { case standard, high }
public enum ImageMime: String, Sendable, Codable { case png, jpeg, webp, gif }
public struct InputImage: Sendable, Equatable {
    let value: JSON
    public init(data: Data, mime: ImageMime, alt: String? = nil, resolution: ImageResolution? = nil) {
        var fields: [String: JSON] = ["data": .string(data.base64EncodedString()), "mime": .string("image/" + mime.rawValue)]
        if let alt { fields["alt"] = .string(alt) }
        if let resolution { fields["resolution"] = .string(resolution.rawValue) }
        value = .object(fields)
    }
    public init(url: URL, alt: String? = nil) {
        var fields: [String: JSON] = ["url": .string(url.absoluteString)]
        if let alt { fields["alt"] = .string(alt) }
        value = .object(fields)
    }
}
public struct StackedInput: Sendable, Equatable {
    public let kind: InputKind
    public let text: String?
    public let images: [InputImage]
    public init(kind: InputKind = .user, text: String? = nil, images: [InputImage] = []) {
        self.kind = kind; self.text = text; self.images = images
    }
}
public struct SendInput: Sendable, Equatable {
    public let id: String
    public let text: String
    public let kind: InputKind
    public let images: [InputImage]
    public let context: JSON?
    public let inputs: [StackedInput]
    public init(id: String, text: String, kind: InputKind = .user, images: [InputImage] = [], context: JSON? = nil) {
        self.init(id: id, text: text, kind: kind, images: images, inputs: [], context: context)
    }
    public init(id: String, inputs: [StackedInput], context: JSON? = nil) {
        self.init(id: id, text: "", kind: .user, images: [], inputs: inputs, context: context)
    }
    // Internal malformed-input construction for contract tests and fixture JSON;
    // the public initializers select one form.
    init(id: String, text: String, kind: InputKind, images: [InputImage], inputs: [StackedInput], context: JSON?) {
        self.id = id; self.text = text; self.kind = kind; self.images = images; self.inputs = inputs; self.context = context
    }
    func wireJSON() throws -> JSON {
        let encoder = JSONEncoder()
        func kindJSON(_ kind: InputKind) throws -> JSON { try JSON(data: encoder.encode(kind)) }
        var fields: [String: JSON] = ["id": .string(id)]
        if let context { fields["context"] = context }
        if !inputs.isEmpty {
            fields["inputs"] = .array(try inputs.map { part in
                var partFields: [String: JSON] = ["kind": try kindJSON(part.kind)]
                if let text = part.text { partFields["text"] = .string(text) }
                if !part.images.isEmpty { partFields["images"] = .array(part.images.map(\.value)) }
                return .object(partFields)
            })
            if !text.isEmpty { fields["text"] = .string(text) }
            if kind != .user { fields["kind"] = try kindJSON(kind) }
        } else {
            fields["text"] = .string(text); fields["kind"] = try kindJSON(kind)
        }
        if !images.isEmpty { fields["images"] = .array(images.map(\.value)) }
        guard fields["inputs"] == nil || (fields["text"] == nil && fields["kind"] == nil && fields["images"] == nil) else {
            throw CrocheError("invalid_input", "Send either text and kind (one input) or inputs (a stack), not both")
        }
        return .object(fields)
    }
    func coreJSON(options: SendOptions) throws -> JSON {
        let value = try wireJSON()
        #if CROCHE_SUBSCRIPTION_HOST
        return value
        #else
        return Images.prepareInput(value, fallback: options.imageResolution)
        #endif
    }
}
public struct SendOptions: Sendable, Equatable {
    public let responseFormat: JSON?
    public let imageResolution: ImageResolution?
    public init(responseFormat: JSON? = nil, imageResolution: ImageResolution? = nil) {
        self.responseFormat = responseFormat; self.imageResolution = imageResolution
    }
}
public enum RequestWait: Sendable { case idle }
public struct Receipt: Sendable, Equatable { public let id: String; public let status: InputStatus; public let seq: Int? }
public struct RequestResult: Sendable, Equatable {
    public let id: String
    public let status: InputStatus
    public let messages: [MessageEnd]
    public let gap: Bool
    public let legacy: Bool
    // RequestResult.pending comes with the coordinated TS/Swift/Kotlin consuming-unit change.
}
public struct Cursor: Sendable, Codable, Hashable {
    public let logId: String
    public let seq: Int
    public init(logId: String, seq: Int) { self.logId = logId; self.seq = seq }
}
public struct StreamError: Sendable, Codable, Equatable { public let code: String; public let message: String; public let poisoned: Bool }
public struct RuntimeError: Sendable, Codable, Hashable { public let code: String; public let message: String }
public struct ToolSource: Sendable, Codable, Equatable { public let command: String; public let callId: String }
public struct ImageSummary: Sendable, Codable, Equatable { public let alt: String?; public let mime: String?; public let bytes: Int? }
public struct InputEvent: Sendable, Codable, Equatable {
    public let seq: Int; public let firstSeq: Int; public let id: String; public let kind: InputKind
    public let text: String?; public let images: [ImageSummary]; public let status: InputStatus
    public let error: RuntimeError?; public let at: Date
}
public struct MessageStart: Sendable, Codable, Equatable { public let seq: Int; public let firstSeq: Int; public let id: String; public let at: Date }
public struct MessageDelta: Sendable, Codable, Equatable { public let id: String; public let text: String }
public struct MessageEnd: Sendable, Codable, Equatable {
    public let seq: Int; public let firstSeq: Int; public let id: String
    public let status: MessageStatus; public let text: String; public let markers: [String]; public let output: JSON?
    public let inReplyTo: [String]; public let causedBy: [String]; public let error: RuntimeError?; public let at: Date
}
public struct Cleared: Sendable, Codable, Equatable { public let seq: Int; public let id: String; public let at: Date }
public struct Page: Sendable, Equatable { public let messages: [RuntimeEvent]; public let reachedFloor: Bool; public let logId: String; public let clearedSeq: Int }
public struct AppStreamEvent: Sendable, Codable, Equatable { public let seq: Int; public let id: String; public let name: String; public let data: JSON; public let source: ToolSource; public let at: Date }
public struct TurnEvent: Sendable, Codable, Equatable {
    public let seq: Int; public let id: String; public let causedBy: [String]; public let inputs: [String]; public let purpose: String; public let usage: [String: Int]
    public let costUsd: Double; public let costStatus: CostStatus; public let model: String; public let imagesOmitted: Int?; public let at: Date
}
public struct StateEvent: Sendable, Codable, Equatable {
    public let status: AgentStatus; public let queued: Int; public let typing: Bool
    /// What a running agent waits on: set exactly while `status` is `.running`, nil otherwise.
    public let activity: AgentActivity?
    /// With `.tool` only: the command keys the round runs, in call order. Never arguments.
    public let tools: [String]?
    public init(status: AgentStatus, queued: Int, typing: Bool, activity: AgentActivity? = nil, tools: [String]? = nil) {
        self.status = status; self.queued = queued; self.typing = typing; self.activity = activity; self.tools = tools
    }
}
public struct ErrorEvent: Sendable, Codable, Equatable { public let seq: Int; public let id: String; public let code: String; public let message: String; public let inputs: [String]; public let at: Date }
public struct Gap: Sendable, Codable, Equatable { public let afterSeq: Int; public let throughSeq: Int; public let reason: GapReason }
public struct Snapshot: Sendable, Codable, Equatable { public let logId: String; public let state: StateEvent; public let streaming: Streaming? }
public struct Streaming: Sendable, Codable, Equatable { public let messageId: String; public let firstSeq: Int; public let text: String }
public enum RuntimeEvent: Sendable, Equatable {
    case input(InputEvent), messageStart(MessageStart), messageDelta(MessageDelta), messageEnd(MessageEnd)
    case cleared(Cleared), page(Page), app(AppStreamEvent), turn(TurnEvent), state(StateEvent), error(ErrorEvent)
    case gap(Gap), snapshot(Snapshot), streamError(StreamError), replaced, unknown(type: String)
    public var seq: Int? {
        switch self {
        case .input(let v): v.seq
        case .messageStart(let v): v.seq
        case .messageEnd(let v): v.seq
        case .cleared(let v): v.seq
        case .app(let v): v.seq
        case .turn(let v): v.seq
        case .error(let v): v.seq
        default: nil
        }
    }
}

public enum InputKind: Sendable, Codable, Hashable {
    case user, event, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "user": self = .user
        case "event": self = .event
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .user: try container.encode("user")
        case .event: try container.encode("event")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public enum InputStatus: Sendable, Codable, Hashable {
    case queued, seen, answered, noReply, failed, cancelled, settledBeforeUpgrade, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "queued": self = .queued
        case "seen": self = .seen
        case "answered": self = .answered
        case "no_reply": self = .noReply
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "settled_before_upgrade": self = .settledBeforeUpgrade
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .queued: try container.encode("queued")
        case .seen: try container.encode("seen")
        case .answered: try container.encode("answered")
        case .noReply: try container.encode("no_reply")
        case .failed: try container.encode("failed")
        case .cancelled: try container.encode("cancelled")
        case .settledBeforeUpgrade: try container.encode("settled_before_upgrade")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public enum MessageStatus: Sendable, Codable, Hashable {
    case completed, failed, cancelled, interrupted, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "interrupted": self = .interrupted
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .completed: try container.encode("completed")
        case .failed: try container.encode("failed")
        case .cancelled: try container.encode("cancelled")
        case .interrupted: try container.encode("interrupted")
        case .unknown(let value): try container.encode(value)
        }
    }
}

/// The stream `state`'s `activity`: a model call, a summary call (held before the reply), or a
/// tool round. A value this SDK does not know yet decodes as `.unknown`, never a stream error.
public enum AgentActivity: Sendable, Codable, Hashable {
    case model, summary, tool, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "model": self = .model
        case "summary": self = .summary
        case "tool": self = .tool
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .model: try container.encode("model")
        case .summary: try container.encode("summary")
        case .tool: try container.encode("tool")
        case .unknown(let value): try container.encode(value)
        }
    }
}
public enum AgentStatus: Sendable, Codable, Hashable {
    case running, waiting, idle, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "running": self = .running
        case "waiting": self = .waiting
        case "idle": self = .idle
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .running: try container.encode("running")
        case .waiting: try container.encode("waiting")
        case .idle: try container.encode("idle")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public enum CostStatus: Sendable, Codable, Hashable {
    case reported, estimated, none, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "reported": self = .reported
        case "estimated": self = .estimated
        case "none": self = .none
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .reported: try container.encode("reported")
        case .estimated: try container.encode("estimated")
        case .none: try container.encode("none")
        case .unknown(let value): try container.encode(value)
        }
    }
}

public enum GapReason: Sendable, Codable, Hashable {
    case cleared, limit, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "cleared": self = .cleared
        case "limit": self = .limit
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .cleared: try container.encode("cleared")
        case .limit: try container.encode("limit")
        case .unknown(let value): try container.encode(value)
        }
    }
}

extension InputStatus {
    var terminal: Bool {
        switch self { case .answered, .noReply, .failed, .cancelled, .settledBeforeUpgrade: true; default: false }
    }
}
func clampedMaintenanceInterval(_ seconds: TimeInterval) throws -> TimeInterval {
    guard seconds.isFinite else { throw CrocheError("invalid_configuration", "maintenanceInterval must be finite") }
    return max(1, seconds)
}

public struct RequestOptions: Sendable {
    public var responseFormat: JSON?
    public var wait: RequestWait?
    public init(responseFormat: JSON? = nil, wait: RequestWait? = nil) { self.responseFormat = responseFormat; self.wait = wait }
}
public struct SubscribeOptions: Sendable {
    public var initialMessages: Int?
    public var after: Cursor?
    public var onEvent: @Sendable (RuntimeEvent) async -> Void
    public init(initialMessages: Int? = nil, after: Cursor? = nil, onEvent: @escaping @Sendable (RuntimeEvent) async -> Void) {
        self.initialMessages = initialMessages; self.after = after; self.onEvent = onEvent
    }
}
public struct HistoryOptions: Sendable {
    public var before: Int?
    public var limit: Int
    public init(before: Int? = nil, limit: Int) { self.before = before; self.limit = limit }
}
public struct AppStreamEnd: Sendable, Equatable {
    public let code: String
}
