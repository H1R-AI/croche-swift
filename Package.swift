// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CrocheRuntime", platforms: [.iOS(.v15)],
  products: [.library(name: "CrocheRuntime", targets: ["CrocheRuntime"])],
  targets: [.binaryTarget(name: "croche_ffiFFI", url: "https://maven.croche.ai/swift/0.5.4/CrocheRuntime.xcframework.zip", checksum: "f39acde34e259218174fb1395b9ec112d62d4c1820a5de581e12f15d5ff5b7c9"),
            .target(name: "CrocheFFI", dependencies: ["croche_ffiFFI"], swiftSettings: [.swiftLanguageMode(.v5)]),
            .target(name: "CrocheRuntime", dependencies: ["CrocheFFI"])])
