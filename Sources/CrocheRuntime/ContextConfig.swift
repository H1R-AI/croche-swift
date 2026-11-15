import Foundation

/// Schema-6 context settings. Core owns defaults and validation.
struct ContextConfig: Sendable {
    /// Target average input tokens per model call, 1...16_777_216.
    var turnTokens: Int?
    /// 0...0.5, default 0.25; controls memory inclusion; zero disables it. Ignored when memory is disabled.
    var memoryShare: Double?
    /// Hard input-token cap per model call, independent of the model's own window, 1...16_777_216.
    var maxTokens: Int?
    init(turnTokens: Int? = nil, memoryShare: Double? = nil, maxTokens: Int? = nil) {
        self.turnTokens = turnTokens
        self.memoryShare = memoryShare
        self.maxTokens = maxTokens
    }
    var json: JSON {
        var value: JSON = .object([:])
        if let turnTokens { value["turnTokens"] = .number(Double(turnTokens)) }
        if let memoryShare { value["memoryShare"] = .number(memoryShare) }
        if let maxTokens { value["maxTokens"] = .number(Double(maxTokens)) }
        return value
    }
}

/// Input size contracts (`limits`), in UTF-16 code units (`String.utf16.count`). An input over
/// one fails with `input_too_large` and is never truncated; `Croche.truncate` cuts text to fit.
/// Core owns defaults and validation.
struct LimitsConfig: Sendable {
    /// Total user and app-event text of one send, 1_000...200_000 (default 32_000).
    var userTextChars: Int?
    /// Total app-state text of one send, 1_000...200_000 (default 32_000).
    var appStateChars: Int?
    /// One tool result's value as compact JSON, 1_000...1_000_000 (default 200_000). Over it,
    /// the turn fails.
    var toolResultChars: Int?
    init(userTextChars: Int? = nil, appStateChars: Int? = nil, toolResultChars: Int? = nil) {
        self.userTextChars = userTextChars
        self.appStateChars = appStateChars
        self.toolResultChars = toolResultChars
    }
    var json: JSON {
        var value: JSON = .object([:])
        if let userTextChars { value["userTextChars"] = .number(Double(userTextChars)) }
        if let appStateChars { value["appStateChars"] = .number(Double(appStateChars)) }
        if let toolResultChars { value["toolResultChars"] = .number(Double(toolResultChars)) }
        return value
    }
}

/// Application memory settings. Core owns defaults and validation.
struct MemoryConfig: Sendable {
    var enabled: Bool?
    var policy: String?
    init(enabled: Bool? = nil, policy: String? = nil) {
        self.enabled = enabled
        self.policy = policy
    }
    var json: JSON {
        var value: JSON = .object([:])
        if let enabled { value["enabled"] = .bool(enabled) }
        if let policy { value["policy"] = .string(policy) }
        return value
    }
}
