import Foundation

/// One entry = one tool, by its registered name. `bind` REPLACES the registration bind as a
/// whole; nil keeps it. Core validates every field.
public struct ToolEntry: Sendable, ExpressibleByStringLiteral {
    public var tool: String
    public var bind: [String: JSON]?
    public var commands: [String]?
    public var guide: String?
    public init(tool: String, bind: [String: JSON]? = nil, commands: [String]? = nil, guide: String? = nil) {
        self.tool = tool; self.bind = bind; self.commands = commands; self.guide = guide
    }
    public init(stringLiteral name: String) { self.init(tool: name) }
    var json: JSON {
        guard bind != nil || commands != nil || guide != nil else { return .string(tool) }
        var fields: [String: JSON] = ["tool": .string(tool)]
        if let bind { fields["bind"] = .object(bind) }
        if let commands { fields["commands"] = .array(commands.map(JSON.string)) }
        if let guide { fields["guide"] = .string(guide) }
        return .object(fields)
    }
}

/// One entry = one path or glob, e.g. `"faq/**"`.
public struct WikiEntry: Sendable, ExpressibleByStringLiteral {
    public var doc: String
    public var guide: String?
    public init(doc: String, guide: String? = nil) { self.doc = doc; self.guide = guide }
    public init(stringLiteral doc: String) { self.init(doc: doc) }
    var json: JSON {
        guard let guide else { return .string(doc) }
        return .object(["doc": .string(doc), "guide": .string(guide)])
    }
}

/// `.all` = every registered; `[]` = none. In `AgentOptions`, nil also means all.
public enum Scope<Entry: Sendable>: Sendable, ExpressibleByArrayLiteral {
    case all
    case list([Entry])
    public init(arrayLiteral entries: Entry...) { self = .list(entries) }
}
public typealias ToolScope = Scope<ToolEntry>
public typealias WikiScope = Scope<WikiEntry>

/// `{path, description, markdown}` or `{path, description, file}`. iOS resolves `file` as a
/// main-bundle resource or a `file://` URL, when Core reads it.
public enum WikiDoc: Sendable, Equatable {
    case markdown(path: String, description: String, markdown: String)
    case file(path: String, description: String, file: String)
    var json: JSON {
        switch self {
        case let .markdown(path, description, markdown):
            .object(["path": .string(path), "description": .string(description), "markdown": .string(markdown)])
        case let .file(path, description, file):
            .object(["path": .string(path), "description": .string(description), "file": .string(file)])
        }
    }
    init(_ value: JSON) throws {
        guard let path = value["path"].string, let description = value["description"].string else {
            throw CrocheError(code: "internal", message: "Core's wiki document has no path or description.", category: .internal)
        }
        if let markdown = value["markdown"].string { self = .markdown(path: path, description: description, markdown: markdown) }
        else if let file = value["file"].string { self = .file(path: path, description: description, file: file) }
        else { throw CrocheError(code: "internal", message: "Core's wiki document has no body.", category: .internal) }
    }
}

public struct AgentInstance: Sendable {
    public var id: String
    /// A patch over the agent config. NOT saved: pass it on every open.
    public var config: JSON?
    public init(id: String, config: JSON? = nil) { self.id = id; self.config = config }
}

public struct AgentOptions: Sendable {
    /// nil = the agent's default instance.
    public var instance: AgentInstance?
    /// nil or `.all` = all registered; `[]` = none.
    public var tools: ToolScope?
    public var wiki: WikiScope?
    public init(instance: AgentInstance? = nil, tools: ToolScope? = nil, wiki: WikiScope? = nil) {
        self.instance = instance; self.tools = tools; self.wiki = wiki
    }
    var json: JSON {
        var fields: [String: JSON] = [:]
        if let instance {
            var value: [String: JSON] = ["id": .string(instance.id)]
            if let config = instance.config { value["config"] = config }
            fields["instance"] = .object(value)
        }
        if let tools { fields["tools"] = tools.json(\.json) }
        if let wiki { fields["wiki"] = wiki.json(\.json) }
        return .object(fields)
    }
}

public struct OpenOptions: Sendable {
    public var projectKey: String
    public var user: String?
    /// nil = omitted: Core chooses (ARCHITECTURE §2: the device locale is a PAL fact, never an SDK default).
    public var language: String?
    public var bundledConfig: JSON
    /// nil = omitted; `[]` is sent as `[]` (APP-API gives an empty list its own meaning).
    public var tools: [ToolRegistration]?
    /// nil = omitted; `[]` is sent as `[]`.
    public var wiki: [WikiDoc]?
    /// ARCHITECTURE §2a; nil = the platform default.
    public var storage: (any StoragePal)?
    public var serverKey: String?
    public var debugKey: String?
    public init(projectKey: String, bundledConfig: JSON, user: String? = nil, language: String? = nil,
                tools: [ToolRegistration]? = nil, wiki: [WikiDoc]? = nil, storage: (any StoragePal)? = nil,
                serverKey: String? = nil, debugKey: String? = nil) {
        self.projectKey = projectKey; self.bundledConfig = bundledConfig; self.user = user; self.language = language
        self.tools = tools; self.wiki = wiki; self.storage = storage; self.serverKey = serverKey; self.debugKey = debugKey
    }
    /// The WHOLE options as JSON (Atlas's S1 ABI): only the opaque tool and storage references
    /// become null; the tools themselves travel beside it as registrations, in this order.
    var json: JSON {
        var fields: [String: JSON] = ["projectKey": .string(projectKey), "bundledConfig": bundledConfig]
        if let user { fields["user"] = .string(user) }
        if let language { fields["language"] = .string(language) }
        if let tools { fields["tools"] = .array(tools.map(\.json)) }
        if let wiki { fields["wiki"] = .array(wiki.map(\.json)) }
        if storage != nil { fields["storage"] = .null }
        if let serverKey { fields["serverKey"] = .string(serverKey) }
        if let debugKey { fields["debugKey"] = .string(debugKey) }
        return .object(fields)
    }
}

/// `Croche.registerBackground`. `storage` = the one `open()` uses.
public struct BackgroundOptions: Sendable {
    public var sink: (@Sendable (BackgroundEvent) -> Void)?
    public var storage: (any StoragePal)?
    public init(sink: (@Sendable (BackgroundEvent) -> Void)? = nil, storage: (any StoragePal)? = nil) {
        self.sink = sink; self.storage = storage
    }
    /// As `OpenOptions.json`: the opaque sink and storage become null.
    var json: JSON {
        var fields: [String: JSON] = [:]
        if sink != nil { fields["sink"] = .null }
        if storage != nil { fields["storage"] = .null }
        return .object(fields)
    }
}

/// `croche.deleteData(_:)` on an opened Croche: `{agent}`, `{agent, instance}` or `{}`. Core rejects
/// `{instance}` alone. A recovery handle accepts only `{}` or no scope.
public struct DataScope: Sendable {
    public var agent: String?
    public var instance: String?
    public init(agent: String? = nil, instance: String? = nil) { self.agent = agent; self.instance = instance }
    var json: JSON {
        var fields: [String: JSON] = [:]
        if let agent { fields["agent"] = .string(agent) }
        if let instance { fields["instance"] = .string(instance) }
        return .object(fields)
    }
}

extension Scope {
    func json(_ entry: (Entry) -> JSON) -> JSON {
        switch self {
        case .all: .string("all")
        case .list(let entries): .array(entries.map(entry))
        }
    }
}

/// The second argument of `Croche.open(_:recovery:)`. Swift serializes `{"recover": recover}`;
/// Core alone validates it (`"delete"` today; anything else is `invalid_request`).
public struct RecoveryOptions: Sendable, Equatable {
    public let recover: String
    public init(recover: String) { self.recover = recover }
    var json: JSON { .object(["recover": .string(recover)]) }
}
