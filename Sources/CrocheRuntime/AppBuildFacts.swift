import CrocheFFI
import Foundation

/// Whether the app's own code signature grants `get-task-allow`, the entitlement the OS checks
/// before it lets a debugger attach. It comes from the running executable, never from app options
/// or a build macro: a macro here would describe this SDK's build, not the app's.
///
/// Only the XML entitlements slot is read. A signature without it reads as `false`; anything that
/// cannot be parsed reads as `nil` (unknown), and the caller refuses both.
enum AppBuildFacts {
    /// From this slice's own compile target, never from options. iOS means device or simulator;
    /// every other Apple or Linux host is Other, which has no build gate.
    static var targetKind: PalTargetKind {
        #if targetEnvironment(simulator)
        return .iosSimulator
        #elseif os(iOS)
        return .iosDevice
        #else
        return .other
        #endif
    }

    /// The OS's own notion of debuggable for this process. The simulator has no such fact (no
    /// slice carries the entitlement, Debug or Release), so a simulator build counts as debuggable
    /// by rule: it cannot run on a device. Device rule: documented, not yet device-proven.
    static let debuggable: Bool? = {
        #if targetEnvironment(simulator)
        return true
        #elseif os(iOS)
        return ProcessInfo.processInfo.isiOSAppOnMac ? nil : getTaskAllow(executable: Bundle.main.executableURL)
        #else
        return nil
        #endif
    }()

    static func getTaskAllow(executable: URL?) -> Bool? {
        guard let executable, let data = try? Data(contentsOf: executable, options: .alwaysMapped) else { return nil }
        return getTaskAllow(macho: data)
    }

    static func getTaskAllow(macho data: Data) -> Bool? {
        let bytes = Bytes(data: Data(data))
        guard let slice = arm64Slice(bytes), let signature = signature(slice) else { return nil }
        return entitlement(signature)
    }

    /// The arm64 Mach-O: the file itself, or that slice of a universal binary.
    private static func arm64Slice(_ file: Bytes) -> Bytes? {
        if file.be32(0) == 0xcafe_babe {
            guard let count = file.be32(4) else { return nil }
            for index in 0..<Int(min(count, 64)) {
                let entry = 8 + index * 20
                guard file.be32(entry) == 0x0100_000c else { continue }
                guard let offset = file.be32(entry + 8), let size = file.be32(entry + 12) else { return nil }
                return file.range(Int(offset), Int(size))
            }
            return nil
        }
        return file.le32(0) == 0xfeed_facf ? file : nil
    }

    /// The SuperBlob `LC_CODE_SIGNATURE` points at.
    private static func signature(_ macho: Bytes) -> Bytes? {
        guard let count = macho.le32(16) else { return nil }
        var command = 32
        for _ in 0..<Int(min(count, 4096)) {
            guard let kind = macho.le32(command), let size = macho.le32(command + 4), size >= 8 else { return nil }
            if kind == 0x1d {
                guard let offset = macho.le32(command + 8), let length = macho.le32(command + 12),
                      let blob = macho.range(Int(offset), Int(length)), blob.be32(0) == 0xfade_0cc0 else { return nil }
                return blob
            }
            command += Int(size)
        }
        return nil
    }

    private static func entitlement(_ superblob: Bytes) -> Bool? {
        guard let count = superblob.be32(8), count <= 64 else { return nil }
        for index in 0..<Int(count) {
            let entry = 12 + index * 8
            guard let slot = superblob.be32(entry), let offset = superblob.be32(entry + 4) else { return nil }
            guard slot == 5 else { continue }
            guard superblob.be32(Int(offset)) == 0xfade_7171, let length = superblob.be32(Int(offset) + 4), length >= 8,
                  let xml = superblob.range(Int(offset) + 8, Int(length) - 8),
                  let plist = try? PropertyListSerialization.propertyList(from: xml.slice, format: nil),
                  let entitlements = plist as? [String: Any] else { return nil }
            return entitlements["get-task-allow"] as? Bool ?? false
        }
        return false
    }

    /// Bounds-checked reads over a zero-based range of the file: hostile offsets return nil.
    private struct Bytes {
        let data: Data
        let start: Int
        let count: Int
        init(data: Data) { self.data = data; start = 0; count = data.count }
        private init(data: Data, start: Int, count: Int) { self.data = data; self.start = start; self.count = count }

        var slice: Data { data.subdata(in: start..<(start + count)) }
        func range(_ offset: Int, _ length: Int) -> Bytes? {
            guard offset >= 0, length >= 0, offset <= count, length <= count - offset else { return nil }
            return Bytes(data: data, start: start + offset, count: length)
        }
        func be32(_ offset: Int) -> UInt32? { word(offset).map { $0.reduce(0) { $0 << 8 | UInt32($1) } } }
        func le32(_ offset: Int) -> UInt32? { word(offset).map { $0.reversed().reduce(0) { $0 << 8 | UInt32($1) } } }
        private func word(_ offset: Int) -> [UInt8]? {
            guard offset >= 0, offset <= count - 4 else { return nil }
            return [UInt8](data[(start + offset)..<(start + offset + 4)])
        }
    }
}
