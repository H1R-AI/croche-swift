import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Private legacy image preparation still uses this; it is not an App API export.
enum ImageResolution: String, Sendable, Codable { case standard, high }
/** One ordered input element. Core owns all validation, defaults and admission. */
public enum SendElement: Sendable, Equatable {
    case text(String, kind: InputKind? = nil)
    case image(ImageInput)
    func wireJSON() throws -> JSON {
        switch self {
        case .text(let text, let kind):
            var fields: [String: JSON] = ["type": .string("text"), "text": .string(text)]
            if let kind { fields["kind"] = try JSON(data: JSONEncoder().encode(kind)) }
            return .object(fields)
        case .image(let image): return try image.wireJSON()
        }
    }
}
/** One image element, supplied by URI or encoded bytes (APP-API ImageInput: uri or bytes, alt). */
public struct ImageInput: Sendable, Equatable {
    public let uri: String?
    private let image: Data?
    public let alt: String?
    public init(uri: String, alt: String? = nil) {
        self.uri = uri; image = nil; self.alt = alt
    }
    /// Encoded JPEG or PNG bytes. They are captured when the send is reserved; Core decodes and
    /// sizes them through this platform's codec (ImageIO).
    public init(image: Data, alt: String? = nil) {
        uri = nil; self.image = image; self.alt = alt
    }
    #if canImport(UIKit) && canImport(ImageIO) && !CROCHE_SUBSCRIPTION_HOST
    /// A UIImage, drawn upright and encoded once as PNG now; then the same as `init(image: Data)`.
    public init(image: UIImage, alt: String? = nil) throws {
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        let upright = UIGraphicsImageRenderer(size: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale), format: format)
            .image { _ in image.draw(in: CGRect(x: 0, y: 0, width: image.size.width * image.scale, height: image.size.height * image.scale)) }
        self.init(image: try NativeImagePal.encodedPNG(upright.cgImage), alt: alt)
    }
    #elseif canImport(AppKit) && canImport(ImageIO) && !CROCHE_SUBSCRIPTION_HOST
    /// An NSImage, encoded once as PNG now; then the same as `init(image: Data)`.
    public init(image: NSImage, alt: String? = nil) throws {
        var rect = CGRect(origin: .zero, size: image.size)
        self.init(image: try NativeImagePal.encodedPNG(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)),
                  alt: alt)
    }
    #endif
    /// Bytes to capture at the reserved send entry; nil for a URI.
    var capturedBytes: Data? { image }
    func wireJSON() throws -> JSON {
        // Owned bytes ride beside the JSON as a capture at this element's index. The element names
        // neither bytes nor a slot: Core joins the position and writes `image: null` itself.
        if image != nil {
            var fields: [String: JSON] = ["type": .string("image")]
            if let alt { fields["alt"] = .string(alt) }
            return .object(fields)
        }
        var fields: [String: JSON] = ["type": .string("image"), "uri": .string(uri!)]
        if let alt { fields["alt"] = .string(alt) }
        return .object(fields)
    }
}
/** One request; only an absent id asks Core to generate its identity. */
public struct SendInput: Sendable, Equatable {
    public let id: String?
    public let input: [SendElement]
    public init(id: String? = nil, input: [SendElement]) { self.id = id; self.input = input }
    func wireJSON() throws -> JSON {
        var fields: [String: JSON] = ["input": .array(try input.map { try $0.wireJSON() })]
        if let id { fields["id"] = .string(id) }
        return .object(fields)
    }
    func coreJSON(options: SendOptions) throws -> JSON { try wireJSON() }
    /// The image elements given as bytes, by their position in `input`.
    func imageCaptures() -> [(element: Int, bytes: Data)] {
        input.enumerated().compactMap { index, element in
            if case .image(let image) = element, let bytes = image.capturedBytes { return (index, bytes) }
            return nil
        }
    }
}
public struct SendOptions: Sendable, Equatable {
    public let responseFormat: JSON?
    public init(responseFormat: JSON? = nil) { self.responseFormat = responseFormat }
}
public enum RequestWait: Sendable { case idle }
struct LegacyReceipt: Sendable, Equatable { public let requestId: String; public let status: LegacyInputStatus; public let seq: Int? }
struct LegacyRequestResult: Sendable, Equatable {
    public let id: String
    public let status: LegacyInputStatus
    public let messages: [LegacyMessageEnd]
    public let gap: Bool
    public let legacy: Bool
    // RequestResult.pending comes with the coordinated TS/Swift/Kotlin consuming-unit change.
}
public struct Cursor: Sendable, Codable, Hashable {
    public let logId: String
    public let seq: Int
    public init(logId: String, seq: Int) { self.logId = logId; self.seq = seq }
}
struct LegacyStreamError: Sendable, Codable, Equatable { public let code: String; public let message: String; public let poisoned: Bool }
struct LegacyRuntimeError: Sendable, Codable, Hashable { public let code: String; public let message: String }
struct LegacyToolSource: Sendable, Codable, Equatable { public let command: String; public let callId: String }
struct LegacyImageSummary: Sendable, Codable, Equatable { public let alt: String?; public let mime: String?; public let bytes: Int? }
struct LegacyInputEvent: Sendable, Codable, Equatable {
    public let seq: Int; public let firstSeq: Int; public let id: String; public let kind: InputKind
    public let text: String?; public let images: [LegacyImageSummary]; public let status: LegacyInputStatus
    public let error: LegacyRuntimeError?; public let at: Date
}
struct LegacyMessageStart: Sendable, Codable, Equatable { public let seq: Int; public let firstSeq: Int; public let id: String; public let at: Date }
struct LegacyMessageDelta: Sendable, Codable, Equatable { public let id: String; public let text: String }
struct LegacyMessageEnd: Sendable, Codable, Equatable {
    public let seq: Int; public let firstSeq: Int; public let id: String
    public let status: LegacyMessageStatus; public let text: String; public let markers: [String]; public let output: JSON?
    public let inReplyTo: [String]; public let causedBy: [String]; public let error: LegacyRuntimeError?; public let at: Date
}
struct LegacyCleared: Sendable, Codable, Equatable { public let seq: Int; public let id: String; public let at: Date }
struct LegacyPage: Sendable, Equatable { public let messages: [LegacyRuntimeEvent]; public let reachedFloor: Bool; public let logId: String; public let clearedSeq: Int }
struct LegacyAppStreamEvent: Sendable, Codable, Equatable { public let seq: Int; public let id: String; public let name: String; public let data: JSON; public let source: LegacyToolSource; public let at: Date }
struct LegacyTurnEvent: Sendable, Codable, Equatable {
    public let seq: Int; public let id: String; public let causedBy: [String]; public let inputs: [String]; public let purpose: String; public let usage: [String: Int]
    public let costUsd: Double; public let costStatus: LegacyCostStatus; public let model: String; public let imagesOmitted: Int?; public let at: Date
}
struct LegacyStateEvent: Sendable, Codable, Equatable {
    public let status: LegacyAgentStatus; public let queued: Int; public let typing: Bool
    /// What a running agent waits on: set exactly while `status` is `.running`, nil otherwise.
    public let activity: LegacyAgentActivity?
    /// With `.tool` only: the command keys the round runs, in call order. Never arguments.
    public let tools: [String]?
    public init(status: LegacyAgentStatus, queued: Int, typing: Bool, activity: LegacyAgentActivity? = nil, tools: [String]? = nil) {
        self.status = status; self.queued = queued; self.typing = typing; self.activity = activity; self.tools = tools
    }
}
struct LegacyErrorEvent: Sendable, Codable, Equatable { public let seq: Int; public let id: String; public let code: String; public let message: String; public let inputs: [String]; public let at: Date }
struct LegacyGap: Sendable, Codable, Equatable { public let afterSeq: Int; public let throughSeq: Int; public let reason: LegacyGapReason }
struct LegacySnapshot: Sendable, Codable, Equatable { public let logId: String; public let state: LegacyStateEvent; public let streaming: LegacyStreaming? }
struct LegacyStreaming: Sendable, Codable, Equatable { public let messageId: String; public let firstSeq: Int; public let text: String }
enum LegacyRuntimeEvent: Sendable, Equatable {
    case input(LegacyInputEvent), messageStart(LegacyMessageStart), messageDelta(LegacyMessageDelta), messageEnd(LegacyMessageEnd)
    case cleared(LegacyCleared), page(LegacyPage), app(LegacyAppStreamEvent), turn(LegacyTurnEvent), state(LegacyStateEvent), error(LegacyErrorEvent)
    case gap(LegacyGap), snapshot(LegacySnapshot), streamError(LegacyStreamError), replaced
    /// An event type this SDK does not know (D-e: reader types are open): its type and every
    /// other field, kept as they came. Ignore it, or read `fields`.
    case unknown(type: String, fields: JSON = .object([:]))
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
    case user, appEvent, appState, unknown(String)
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "user": self = .user
        case "app_event": self = .appEvent
        case "app_state": self = .appState
        default: self = .unknown(value)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .user: try container.encode("user")
        case .appEvent: try container.encode("app_event")
        case .appState: try container.encode("app_state")
        case .unknown(let value): try container.encode(value)
        }
    }
}

enum LegacyInputStatus: Sendable, Codable, Hashable {
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

enum LegacyMessageStatus: Sendable, Codable, Hashable {
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
enum LegacyAgentActivity: Sendable, Codable, Hashable {
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
enum LegacyAgentStatus: Sendable, Codable, Hashable {
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

enum LegacyCostStatus: Sendable, Codable, Hashable {
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

enum LegacyGapReason: Sendable, Codable, Hashable {
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

extension LegacyInputStatus {
    var terminal: Bool {
        switch self { case .answered, .noReply, .failed, .cancelled, .settledBeforeUpgrade: true; default: false }
    }
}
func clampedMaintenanceInterval(_ seconds: TimeInterval) throws -> TimeInterval {
    guard seconds.isFinite else { throw LegacyCrocheError("invalid_configuration", "maintenanceInterval must be finite") }
    return max(1, seconds)
}

public struct RequestOptions: Sendable {
    public var responseFormat: JSON?
    public var wait: RequestWait?
    public init(responseFormat: JSON? = nil, wait: RequestWait? = nil) { self.responseFormat = responseFormat; self.wait = wait }
}
struct LegacySubscribeOptions: Sendable {
    public var initialMessages: Int?
    public var after: Cursor?
    /// How Core batches `messageDelta`. Nil = omitted: Core applies its platform default. The SDK
    /// sets none and passes a value (0 included) to Core unchanged.
    public var deltaMs: Int?
    public var onEvent: @Sendable (LegacyRuntimeEvent) async -> Void
    public init(initialMessages: Int? = nil, after: Cursor? = nil, deltaMs: Int? = nil, onEvent: @escaping @Sendable (LegacyRuntimeEvent) async -> Void) {
        self.initialMessages = initialMessages; self.after = after; self.deltaMs = deltaMs; self.onEvent = onEvent
    }
}
struct LegacyHistoryOptions: Sendable {
    public var before: Int?
    public var limit: Int
    public init(before: Int? = nil, limit: Int) { self.before = before; self.limit = limit }
}
struct LegacyAppStreamEnd: Sendable, Equatable {
    public let code: String
}
