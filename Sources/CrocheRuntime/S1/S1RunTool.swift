import Foundation
import CrocheFFI

/// Core's one result envelope. A plugin's output remains arbitrary JSON.
public enum RunToolResult: Sendable {
    public struct Ok: Sendable {
        public let id: String
        public let output: JSON
        public let attachments: [AppStreamContract.Attachment]
        public let cost: Double?
        public let costStatus: String
    }
    public struct Failed: Sendable {
        public let id: String, code: String, message: String
        public let category: ErrorCategory
        public let cost: Double?
        public let costStatus: String
    }
    public struct Lost: Sendable {
        public let id: String, code: String, message: String
        public let category: ErrorCategory
    }
    case ok(Ok)
    case failed(Failed)
    case lost(Lost)
    case unknown(status: String, fields: JSON)

    init(_ value: JSON) throws {
        func string(_ key: String) throws -> String {
            guard let result = value[key].string else { throw malformed("runTool \(key)") }
            return result
        }
        func category() throws -> ErrorCategory {
            guard let result = ErrorCategory(rawValue: try string("category")) else { throw malformed("runTool category") }
            return result
        }
        switch try string("status") {
        case "ok":
            guard value.object?["output"] != nil else { throw malformed("runTool output") }
            let attachments = try JSONDecoder().decode([AppStreamContract.Attachment].self,
                from: Data(text(value["attachments"]).utf8))
            self = .ok(Ok(id: try string("id"), output: value["output"], attachments: attachments,
                cost: value["cost"].number, costStatus: try string("costStatus")))
        case "failed":
            self = .failed(Failed(id: try string("id"), code: try string("code"), message: try string("message"),
                category: try category(), cost: value["cost"].number, costStatus: try string("costStatus")))
        case "lost":
            self = .lost(Lost(id: try string("id"), code: try string("code"), message: try string("message"), category: try category()))
        case let status: self = .unknown(status: status, fields: value)
        }
    }
}

public extension Croche {
    /// Cancelling the Task detaches this caller; Core owns the dispatched effect.
    func runTool(_ name: String, args: [String: JSON], id: String) async throws -> RunToolResult {
        let core = self.core, arguments = text(.object(args)), options = text(.object(["id": .string(id)]))
        return try RunToolResult(reply(try await cancellable {
            try core.runTool(name: name, argsJson: arguments, optionsJson: options, cancel: $0)
        }))
    }
}
