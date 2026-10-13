import Foundation
import CrocheFFI
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// How an image is sent (F30, H3). `standard` (the default): at most 512 px on its longest side,
/// never upscaled, as PNG or JPEG, whichever is smaller (transparency kept as PNG; a GIF becomes
/// its first frame). `high`: as given, within the limits (3 MB each, 6 MB together), for text,
/// screenshots and dense detail. An https `url` image is never changed. An image's own
/// `"resolution"` wins over the send's or the tool result's.


/// A tool's result with images beside its value (H3): the same image kinds and limits as a
/// message's (`{"data", "mime", "alt"}` or `{"url"}`, at most 4); a violation fails that call
/// with `invalid_tool_result`, and the turn goes on. Return it from a handler made with
/// `withResult`.
public struct ToolResult: Sendable {
    public var value: JSON
    public var images: [JSON]
    /// For every image that does not name its own `"resolution"`.
    public var imageResolution: ImageResolution?
    public init(value: JSON = .null, images: [JSON] = [], imageResolution: ImageResolution? = nil) {
        self.value = value; self.images = images; self.imageResolution = imageResolution
    }
}

/// The one way to return a `ToolResult` (its value, plus images):
/// `tools: ["room": withResult { invocation, context in ToolResult(value: ..., images: [...]) }]`.
/// The images go to the Runtime beside the value; a plain `ToolHandler`'s JSON is never looked
/// inside.
public func withResult(_ handler: @escaping @Sendable (_ invocation: JSON, _ context: ToolContext) async throws -> ToolResult) -> ToolHandler {
    { invocation, context in
        let result = try await handler(invocation, context)
        // The handler ran: what it returned (plain values, nothing that can throw) is read once,
        // here; a malformed image passes unchanged and fails this call alone in the Core.
        context.images?.put(result.images.map { Images.prepare($0, fallback: result.imageResolution) })
        return result.value
    }
}

/// Where a `withResult` handler leaves its images for the call that ran it.
final class ImageSink: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [JSON] = []
    func put(_ images: [JSON]) { lock.withLock { self.images = images } }
    func take() -> [JSON] { lock.withLock { images } }
}

enum Images {
    static let standardMaxSide = 512
    static let jpegQuality = 0.7

    /// A send's input with its single or stacked images prepared.
    static func prepareInput(_ input: JSON, fallback: ImageResolution?) -> JSON {
        guard let stack = input["inputs"].array else {
            guard let images = input["images"].array else { return input }
            var out = input
            out["images"] = .array(images.map { prepare($0, fallback: fallback) })
            return out
        }
        var out = input
        out["inputs"] = .array(stack.map { item in
            guard let images = item["images"].array else { return item }
            var item = item
            item["images"] = .array(images.map { prepare($0, fallback: fallback) })
            return item
        })
        return out
    }

    /// The image as it is sent: its resolution resolved and removed. Anything it cannot read
    /// passes unchanged, for the Core to judge.
    static func prepare(_ image: JSON, fallback: ImageResolution?) -> JSON {
        // Malformed: exactly as given, for the Core to refuse (never rebuilt into a clean image).
        guard var given = image.object, wellFormed(given) != nil else { return image }
        let resolution = given.removeValue(forKey: "resolution")?.string.flatMap(ImageResolution.init) ?? fallback ?? .standard
        guard resolution == .standard, let data = given["data"]?.string, let (mime, bytes) = decoded(data, given["mime"]?.string),
              let best = reencoded(bytes, mime) else { return .object(given) }
        var sent: [String: JSON] = ["data": .string(best.data.base64EncodedString()), "mime": .string(best.mime)]
        if let alt = given["alt"] { sent["alt"] = alt }
        return .object(sent)
    }

    static let mimes: Set<String> = ["image/png", "image/jpeg", "image/webp", "image/gif"]
    /// A base64 image the Core would accept as given, by its shape (the Core's own rules: `data`
    /// and no `url`, its mime one of the four and agreeing with a data URL's, base64 text, an
    /// `alt` of at most 500 characters): its mime, or nil. Only such an image is re-encoded
    /// (Atlas, #351 P1-3); anything else passes unchanged, so the Core refuses it as it would with
    /// no codec. Sizes are judged on what is sent, after re-encoding.
    static func wellFormed(_ image: [String: JSON]) -> String? {
        func absent(_ key: String) -> Bool { image[key] == nil || image[key] == .null }
        guard image["url"] == nil, let data = image["data"]?.string else { return nil }
        var mime: String? = nil
        if !absent("mime") {
            guard let m = image["mime"]?.string, mimes.contains(m) else { return nil }
            mime = m
        }
        if !absent("alt") {
            guard let alt = image["alt"]?.string, alt.utf16.count <= 500 else { return nil }
        }
        var body = Substring(data)
        if data.hasPrefix("data:") {
            guard let comma = data.firstIndex(of: ",") else { return nil }
            let head = data[data.index(data.startIndex, offsetBy: 5)..<comma]
            guard head.hasSuffix(";base64") else { return nil }
            let given = String(head.dropLast(";base64".count))
            if let mime, mime != given { return nil }
            mime = given
            body = data[data.index(after: comma)...]
        }
        guard let mime, mimes.contains(mime) else { return nil }
        let bare = body.reversed().drop(while: { $0 == "=" }).reversed()
        guard !bare.isEmpty, body.count - bare.count <= 2,
              bare.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }) else { return nil }
        return mime
    }

    private static func decoded(_ data: String, _ mime: String?) -> (String, Data)? {
        var body = Substring(data), type = mime
        if data.hasPrefix("data:") {
            guard let comma = data.firstIndex(of: ","), data[..<comma].hasSuffix(";base64") else { return nil }
            type = String(data[data.index(data.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count))
            body = data[data.index(after: comma)...]
        }
        guard let type, let bytes = Data(base64Encoded: String(body)) else { return nil }
        return (type, bytes)
    }

    /// The smallest of PNG, JPEG (when no pixel can be transparent) and, when no resize was
    /// needed, the original; nil when the original is the smallest or cannot be decoded.
    static func reencoded(_ bytes: Data, _ mime: String) -> (data: Data, mime: String)? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let longest = max(width, height)
        // Drawn through the thumbnail path even at full size: it applies the EXIF orientation,
        // which a re-encoded image would otherwise lose. A GIF gives its first frame.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: min(longest, standardMaxSide)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        var candidates: [(data: Data, mime: String)] = []
        if let png = encode(image, "public.png", nil) { candidates.append((png, "image/png")) }
        if opaque, let jpeg = encode(image, "public.jpeg", jpegQuality) { candidates.append((jpeg, "image/jpeg")) }
        guard let best = candidates.min(by: { $0.data.count < $1.data.count }) else { return nil }
        if longest <= standardMaxSide && mime != "image/gif" && bytes.count <= best.data.count { return nil }
        return best
        #else
        return nil
        #endif
    }

    #if canImport(ImageIO)
    private static func encode(_ image: CGImage, _ type: String, _ quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
    #endif

    /// The FFI's image record; a field present but not text fails the call, as the Core would.
    static func record(_ image: JSON) throws -> ToolImage {
        func text(_ key: String) throws -> String? {
            switch image[key] {
            case .null: return nil
            case .string(let v): return v
            default: throw FfiError.Failure(code: "invalid_tool_result", message: "A tool result image's \(key) is text. Its effects may have completed.")
            }
        }
        guard image.object != nil else { throw FfiError.Failure(code: "invalid_tool_result", message: "A tool result image is an object. Its effects may have completed.") }
        return ToolImage(data: try text("data"), url: try text("url"), mime: try text("mime") ?? "", alt: try text("alt"))
    }
}
