import Foundation
import CrocheFFI
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Private native image PAL (Rev 4a), the Swift twin of the TypeScript `ImagePal`. Core owns
/// admission, sizing plans, budgets, deadlines and every URL; this only holds owned captures and
/// decodes/encodes to the plan Core gives. Names, codes and messages match TypeScript.
final class NativeImagePal: @unchecked Sendable {
    // No size, byte or pixel limits of its own (Leo 18:40Z): Core owns admission and passes each
    // bound it applies (read and plan maxBytes, render sizes). Only decoder facts refuse here.

    private let lock = NSLock()
    private var captures: [String: Data] = [:]
    #if canImport(ImageIO)
    /// Decoded pixels by handle: private to this process, never sent across the bridge.
    private var decoded: [String: CGImage] = [:]
    #endif
    private var closed = false

    /// A platform decoder is present (ImageIO). No I/O.
    var codecAvailable: Bool {
        #if canImport(ImageIO)
        return true
        #else
        return false
        #endif
    }

    /// Snapshot encoded bytes at the reserved entry boundary; returns the capture token.
    func capture(_ bytes: Data) throws -> String {
        let owned = Data(bytes) // Value copy: later caller mutation cannot reach it.
        let token = UUID().uuidString
        try lock.withLock {
            if closed { throw LegacyCrocheError("closed", "The Runtime is closed.") }
            captures[token] = owned
        }
        return token
    }

    /// Raw bytes only (#830 b4ace3eb): Core sniffs the MIME type and hashes.
    func read(_ request: PalImageReadRequest, _ cancel: CancelToken) throws -> Data {
        try Self.check(cancel)
        let token: String
        switch request.source {
        case .capture(let value): token = value
        case .local(let uri): return try Self.readLocal(uri, maxBytes: Int(request.maxBytes), cancel)
        }
        // A capture is taken once; a second read finds nothing.
        let bytes = lock.withLock { captures.removeValue(forKey: token) }
        guard let bytes, UInt64(bytes.count) <= request.maxBytes else { throw Self.failure("image_fetch_failed") }
        try Self.check(cancel)
        return bytes
    }

    func prepare(_ source: PalImageBytes, _ plan: PalImagePreparePlan, _ cancel: CancelToken) throws -> PalImageBytes {
        try Self.check(cancel)
        if let side = plan.maxSide, side < 1 { throw Self.failure("image_unsupported") }
        guard codecAvailable else { throw Self.failure("image_unsupported") }
        do {
            return try Self.prepareVerified(source, maxSide: plan.maxSide.map(Int.init), maxBytes: Int(plan.maxBytes), cancel)
        } catch {
            try Self.check(cancel)
            throw Self.failure("image_unsupported")
        }
    }

    /// Idempotent.
    func release(_ token: String) { lock.withLock { _ = captures.removeValue(forKey: token) } }

    func close() {
        lock.withLock {
            closed = true; captures.removeAll()
            #if canImport(ImageIO)
            decoded.removeAll()
            #endif
        }
    }

    // MARK: Local URI (S3: iOS reads file:// only; ph:// is out for 0.6)

    /// A `file://` URL into an owned buffer: bounded by `maxBytes`, read in pieces with a cancel
    /// check between them. Anything else, a missing file, a directory or an oversize file is
    /// `image_fetch_failed`.
    static func readLocal(_ uri: String, maxBytes: Int, _ cancel: CancelToken) throws -> Data {
        guard let url = URL(string: uri), url.isFileURL, !url.path.isEmpty,
              let handle = try? FileHandle(forReadingFrom: url) else { throw failure("image_fetch_failed") }
        defer { try? handle.close() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw failure("image_fetch_failed") }
        var bytes = Data()
        while true {
            try check(cancel)
            // One byte past the bound proves the file is too large without reading all of it.
            let piece = (try? handle.read(upToCount: min(256 * 1024, maxBytes + 1 - bytes.count))) ?? nil
            guard let piece, !piece.isEmpty else { break }
            bytes.append(piece)
            if bytes.count > maxBytes { throw failure("image_fetch_failed") }
        }
        guard !bytes.isEmpty else { throw failure("image_fetch_failed") }
        try check(cancel)
        return bytes
    }

    // MARK: Codec primitives (S3): Core chooses frame, orientation, sizes and formats

    /// Decodes `bytes` (no MIME selects a decoder) into private RGBA8 pixels. `hasAlpha` is true
    /// only when a pixel is not opaque, never because the format could carry alpha.
    func decode(_ bytes: Data, _ options: PalImageDecodeOptions, _ cancel: CancelToken) throws -> PalDecodedImage {
        try Self.check(cancel)
        #if canImport(ImageIO)
        let image = try Self.decodePixels(bytes, frame: Int(options.frame), orient: options.applyOrientation, cancel)
        let hasAlpha = try Self.anyTransparent(image, cancel)
        let handle = UUID().uuidString
        try lock.withLock {
            if closed { throw LegacyCrocheError("closed", "The Runtime is closed.") }
            decoded[handle] = image
        }
        // A cancel that lands after the store still wins; the handle is not leaked.
        if cancel.isCancelled() { releaseDecoded(handle); throw Self.cancelled }
        return PalDecodedImage(handle: handle, width: UInt32(image.width), height: UInt32(image.height), hasAlpha: hasAlpha)
        #else
        throw LegacyCrocheError("invalid_input", "The image could not be decoded.")
        #endif
    }

    /// Encodes a decoded handle at exactly `width`×`height`. `quality` (0...1) applies to JPEG.
    func render(_ request: PalImageRenderRequest, _ cancel: CancelToken) throws -> Data {
        try Self.check(cancel)
        #if canImport(ImageIO)
        guard let image = lock.withLock({ decoded[request.handle] }),
              request.width >= 1, request.height >= 1 else {
            throw Self.failure("image_unsupported")
        }
        if let quality = request.quality, !(0...1).contains(quality) { throw Self.failure("image_unsupported") }
        let jpeg = request.format == .jpeg
        let scaled = try Self.draw(image, width: Int(request.width), height: Int(request.height), opaque: jpeg)
        try Self.check(cancel)
        guard let out = Self.encode(scaled, jpeg ? "public.jpeg" : "public.png", jpeg ? request.quality : nil) else {
            throw Self.failure("image_unsupported")
        }
        try Self.check(cancel)
        return out
        #else
        throw Self.failure("image_unsupported")
        #endif
    }

    /// Live decoded handles (tests prove nothing leaks).
    var decodedCount: Int {
        #if canImport(ImageIO)
        lock.withLock { decoded.count }
        #else
        0
        #endif
    }

    /// Synchronous and idempotent, including after a cancel.
    func releaseDecoded(_ handle: String) {
        #if canImport(ImageIO)
        lock.withLock { _ = decoded.removeValue(forKey: handle) }
        #endif
    }

    #if canImport(ImageIO)

    private static func decodePixels(_ bytes: Data, frame: Int, orient: Bool, _ cancel: CancelToken) throws -> CGImage {
        let undecodable = LegacyCrocheError("invalid_input", "The image could not be decoded.")
        // A truncated JPEG/PNG would be drawn with filler; refuse it as TypeScript does.
        if let mime = mime(bytes), !complete(bytes, mime) { throw undecodable }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              frame >= 0, frame < CGImageSourceGetCount(source),
              CGImageSourceGetStatusAtIndex(source, frame) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, !w.multipliedReportingOverflow(by: h).overflow else { throw undecodable }
        try check(cancel)
        guard let raw = CGImageSourceCreateImageAtIndex(source, frame, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw undecodable }
        try check(cancel)
        let orientation = orient ? ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) : 1
        return try upright(raw, orientation: (1...8).contains(orientation) ? orientation : 1)
    }

    /// Draws into an owned sRGB RGBA8 buffer, applying EXIF orientation 1-8.
    private static func upright(_ image: CGImage, orientation: Int) throws -> CGImage {
        let w = image.width, h = image.height, swapped = (5...8).contains(orientation)
        let outW = swapped ? h : w, outH = swapped ? w : h
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw platformFault }
        let W = CGFloat(outW), H = CGFloat(outH)
        // EXIF orientation as a transform in Core Graphics' bottom-left coordinates.
        let t: CGAffineTransform
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: W, ty: H)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: H)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: W, ty: 0)
        default: t = .identity
        }
        context.concatenate(t)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = context.makeImage() else { throw platformFault }
        return out
    }

    /// True when any pixel's alpha is below 255: a scan of the actual RGBA8 pixels.
    private static func anyTransparent(_ image: CGImage, _ cancel: CancelToken) throws -> Bool {
        guard let data = image.dataProvider?.data, let base = CFDataGetBytePtr(data) else { throw platformFault }
        let row = image.bytesPerRow, w = image.width
        for y in 0..<image.height {
            if y % 256 == 0 { try check(cancel) }
            let line = base + y * row
            for x in 0..<w where line[x * 4 + 3] != 255 { return true }
        }
        return false
    }

    private static func draw(_ image: CGImage, width: Int, height: Int, opaque: Bool) throws -> CGImage {
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { throw failure("image_unsupported") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = context.makeImage() else { throw failure("image_unsupported") }
        return out
    }

    private static func encode(_ image: CGImage, _ type: String, _ quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
    #endif

    // MARK: Preparation (same steps as TypeScript `prepareImageBytes`)

    private static func prepareVerified(_ asset: PalImageBytes, maxSide: Int?, maxBytes: Int, _ cancel: CancelToken) throws -> PalImageBytes {
        let bytes = asset.bytes
        guard let mime = mime(bytes), complete(bytes, mime) else { throw failure("image_unsupported") }
        let digest = sha256(bytes)
        guard asset.sha256 == digest else { throw failure("image_unsupported") }
        try check(cancel)
        #if canImport(ImageIO)
        guard let opened = OpenedImage(bytes) else { throw failure("image_unsupported") }
        let sourceWidth = opened.width, sourceHeight = opened.height
        let scale = maxSide.map { min(1, Double($0) / Double(max(sourceWidth, sourceHeight))) } ?? 1
        var width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        var height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        for attempt in 0..<8 {
            try check(cancel)
            let rendered = try opened.render(width: width, height: height)
            try check(cancel)
            var candidates: [PalImageBytes] = []
            if rendered.png.count <= maxBytes { candidates.append(PalImageBytes(bytes: rendered.png, mime: "image/png", sha256: sha256(rendered.png))) }
            if let jpeg = rendered.jpeg, jpeg.count <= maxBytes { candidates.append(PalImageBytes(bytes: jpeg, mime: "image/jpeg", sha256: sha256(jpeg))) }
            if width == sourceWidth && height == sourceHeight && mime != "image/gif" && !opened.reoriented {
                candidates.append(PalImageBytes(bytes: bytes, mime: mime, sha256: digest))
            }
            if let best = candidates.min(by: { $0.bytes.count < $1.bytes.count }), best.bytes.count <= maxBytes { return best }
            if width == 1 && height == 1 { break }
            // As TypeScript: an oversized source candidate also guides the shrink.
            let bestLength = Double(min(rendered.png.count, rendered.jpeg?.count ?? .max, candidates.map(\.bytes.count).min() ?? .max))
            let shrink = max(0.1, min(0.8, (Double(maxBytes) / bestLength).squareRoot() * 0.9))
            width = attempt == 6 ? 1 : max(1, Int(Double(width) * shrink))
            height = attempt == 6 ? 1 : max(1, Int(Double(height) * shrink))
        }
        #endif
        throw failure("image_unsupported")
    }

    #if canImport(ImageIO)
    /// One decoded source. Dimensions come from the header (upright, after EXIF orientation).
    private final class OpenedImage {
        let source: CGImageSource
        let width: Int, height: Int
        /// EXIF turns the stored pixels, so the unchanged source is not upright as encoded.
        let reoriented: Bool

        init?(_ bytes: Data) {
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) >= 1,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int,
                  let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0,
                  !w.multipliedReportingOverflow(by: h).overflow else { return nil }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapped = (5...8).contains(orientation)
            self.source = source
            width = swapped ? h : w; height = swapped ? w : h
            reoriented = orientation != 1
        }

        /// Upright, exactly `width`×`height`: PNG, and JPEG unless a pixel can be transparent.
        func render(width: Int, height: Int) throws -> (png: Data, jpeg: Data?) {
            // The thumbnail path decodes at reduced size when it can (no full 12 MP bitmap for a
            // 512 px target) and applies the EXIF orientation.
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw NativeImagePal.failure("image_unsupported") }
            let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(thumb.alphaInfo)
            let image = try (thumb.width == width && thumb.height == height) ? thumb : Self.scaled(thumb, width, height, opaque)
            guard let png = Self.encode(image, "public.png", nil) else { throw NativeImagePal.failure("image_unsupported") }
            return (png, opaque ? Self.encode(image, "public.jpeg", Images.jpegQuality) : nil)
        }

        private static func scaled(_ image: CGImage, _ width: Int, _ height: Int, _ opaque: Bool) throws -> CGImage {
            let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { throw NativeImagePal.failure("image_unsupported") }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let out = context.makeImage() else { throw NativeImagePal.failure("image_unsupported") }
            return out
        }

        private static func encode(_ image: CGImage, _ type: String, _ quality: Double?) -> Data? {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary })
            return CGImageDestinationFinalize(destination) ? out as Data : nil
        }
    }
    #endif

    // MARK: Helpers

    static func failure(_ code: String) -> LegacyCrocheError {
        LegacyCrocheError(code, code == "image_fetch_failed" ? "The image could not be read." : "The image could not be prepared.")
    }

    static var cancelled: LegacyCrocheError { LegacyCrocheError("cancelled", "Image preparation was cancelled.") }
    /// CoreGraphics or memory failed while handling bytes that did decode: not a fact about the
    /// app's image (never invalid_input): `internal`, sent literally (Keel 19:10Z, 21:00Z).
    static var platformFault: LegacyCrocheError { LegacyCrocheError("internal", "CoreGraphics could not hold the decoded pixels.") }
    /// Core's token is authoritative; its own terminal code wins over this one.
    static func check(_ cancel: CancelToken) throws {
        if cancel.isCancelled() { throw cancelled }
    }

    static func mime(_ bytes: Data) -> String? {
        let b = [UInt8](bytes.prefix(12))
        func at(_ values: [UInt8]) -> Bool { b.count >= values.count && Array(b[0..<values.count]) == values }
        if at([137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if at([255, 216, 255]) { return "image/jpeg" }
        if at([71, 73, 70, 56]), b.count >= 6, b[4] == 55 || b[4] == 57, b[5] == 97 { return "image/gif" }
        if b.count >= 12, at([82, 73, 70, 70]), b[8] == 87, b[9] == 69, b[10] == 66, b[11] == 80 { return "image/webp" }
        return nil
    }

    /// ImageIO draws a truncated JPEG or PNG with filler; the TypeScript codecs refuse it. A JPEG
    /// must carry its end-of-image marker near the end (trailing camera data is allowed), a PNG
    /// its IEND chunk.
    static func complete(_ bytes: Data, _ mime: String) -> Bool {
        let tail = [UInt8](bytes.suffix(64 * 1024))
        func contains(_ marker: [UInt8]) -> Bool {
            guard tail.count >= marker.count else { return false }
            for i in stride(from: tail.count - marker.count, through: 0, by: -1) where tail[i] == marker[0] && Array(tail[i..<i + marker.count]) == marker { return true }
            return false
        }
        switch mime {
        case "image/jpeg": return contains([0xFF, 0xD9])
        case "image/png": return contains([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        default: return true
        }
    }

    static func sha256(_ bytes: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: bytes))
        #else
        let hex = PortableSHA256.hex([UInt8](bytes))
        var out = Data(capacity: 32), index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!); index = next
        }
        return out
        #endif
    }
}

#if canImport(ImageIO) && (canImport(UIKit) || canImport(AppKit))
extension NativeImagePal {
    /// A platform image as PNG bytes, encoded once at capture time (no EXIF: drawn upright).
    static func encodedPNG(_ cgImage: CGImage?) throws -> Data {
        guard let cgImage else { throw failure("image_unsupported") }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { throw failure("image_unsupported") }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("image_fetch_failed") }
        return out as Data
    }
}
#endif
