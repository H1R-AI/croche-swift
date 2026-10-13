// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CrocheRuntime", platforms: [.iOS(.v15)],
  products: [.library(name: "CrocheRuntime", targets: ["CrocheRuntime"])],
  targets: [.binaryTarget(name: "croche_ffiFFI", url: "https://maven.croche.ai/swift/0.5.1/CrocheRuntime.xcframework.zip", checksum: "a2b79c8475c759999c0c3b42be6e0f18bb8eb672fe3e0b202513c4dd4e84a0e7"),
            .target(name: "CrocheFFI", dependencies: ["croche_ffiFFI"], swiftSettings: [.swiftLanguageMode(.v5)]),
            .target(name: "CrocheRuntime", dependencies: ["CrocheFFI"])])
