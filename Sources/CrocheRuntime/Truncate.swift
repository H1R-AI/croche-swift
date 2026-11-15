import Foundation

extension LegacyCroche {
    /// The longest prefix of `text` that is at most `max` UTF-16 code units (the unit of the
    /// `limits.*Chars` settings): text that fits comes back unchanged, a surrogate pair is never
    /// split (so the result can be one unit short), and nothing is appended. Croche never
    /// truncates an input itself: an input over a limit fails with `input_too_large`, so cut your
    /// own text with this first. A negative `max` throws `invalid_input`.
    static func truncate(_ text: String, max: Int) throws -> String {
        do { return try ffiTruncate(text, Double(max)) } catch { throw LegacyCrocheError(error) }
    }
}
