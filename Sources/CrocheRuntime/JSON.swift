import Foundation

/// A value-semantic JSON tree. Core state and machine stay opaque to the host.
public enum JSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public init(data: Data) throws { self = try JSONDecoder().decode(JSON.self, from: data) }
    public init(_ text: String) throws { try self.init(data: Data(text.utf8)) }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public subscript(_ key: String) -> JSON {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v = object ?? [:]; v[key] = newValue; self = .object(v) }
    }
    public var object: [String: JSON]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSON]? { if case .array(let v) = self { return v }; return nil }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
}

public struct CrocheError: Error, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let receipt: Receipt?
    public init(_ code: String, _ message: String, receipt: Receipt? = nil) { self.code = code; self.message = message; self.receipt = receipt }
    public var description: String { "\(code): \(message)" }
}

// Bridge the existing Core identity key until S1 renames it. No store identity is minted here.
func publicStorageIdentity(_ value: JSON) -> JSON {
    guard var fields = value.object else { return value }
    if fields["storageKey"] == nil { fields["storageKey"] = fields["defaultStorageKey"] }
    fields.removeValue(forKey: "defaultStorageKey")
    return .object(fields)
}

// OPEN(Project→Agent): wire this at Croche.open once the reviewed Swift open surface lands.
// The SDK neither chooses a default nor validates the retention budget; Core owns both.
func coreOpenConfig(_ config: JSON, retentionBytes: Int?) -> JSON {
    guard let retentionBytes else { return config }
    var bound = config
    bound["retentionBytes"] = .number(Double(retentionBytes))
    return bound
}
