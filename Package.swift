// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CrocheRuntime", platforms: [.iOS(.v15)],
  products: [.library(name: "CrocheRuntime", targets: ["CrocheRuntime"])],
  targets: [.binaryTarget(name: "croche_ffiFFI", url: "https://maven.croche.ai/swift/0.5.3/CrocheRuntime.xcframework.zip", checksum: "816630308a602a26d48329fad01a54d922820ef4f401a3ccc3466c1690aa284b"),
            .target(name: "CrocheFFI", dependencies: ["croche_ffiFFI"], swiftSettings: [.swiftLanguageMode(.v5)]),
            .target(name: "CrocheRuntime", dependencies: ["CrocheFFI"])])
