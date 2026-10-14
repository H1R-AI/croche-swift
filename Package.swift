// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CrocheRuntime", platforms: [.iOS(.v15)],
  products: [.library(name: "CrocheRuntime", targets: ["CrocheRuntime"])],
  targets: [.binaryTarget(name: "croche_ffiFFI", url: "https://maven.croche.ai/swift/0.5.2/CrocheRuntime.xcframework.zip", checksum: "cc239543f7530ea0e87a09460915d99c5df93bff9e2ce2332c08aa5b5f96a7b8"),
            .target(name: "CrocheFFI", dependencies: ["croche_ffiFFI"], swiftSettings: [.swiftLanguageMode(.v5)]),
            .target(name: "CrocheRuntime", dependencies: ["CrocheFFI"])])
