import Foundation

/// The binding facts Core reports to Cloud with each Runtime (docs/RUNTIME-CLOUD-PROTOCOL.md):
/// `{sdk, sdk_version, platform}`, passed beside the open JSON, never an OpenOptions member. They
/// are diagnostic and carry no logic; Core adds its own runtime_version.
enum BindingFacts {
    /// This package's version. scripts/release-version.mjs sets it with every other SDK version,
    /// and its --check refuses a value that differs from sdk/swift/VERSION.
    static let sdkVersion = "0.6.0"
    static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(Linux)
        return "linux"
        #elseif os(Windows)
        return "windows"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "unknown" // never "server": an unlisted OS is reported as unknown, not guessed
        #endif
    }
    /// `sdk` is "swift", or "react-native" from the RN iOS bridge, which builds these sources.
    static func json(sdk: String = "swift") -> String {
        text(.object(["sdk": .string(sdk), "sdk_version": .string(sdkVersion), "platform": .string(platform)]))
    }
}
