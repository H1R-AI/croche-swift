// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CrocheRuntime", platforms: [.iOS(.v15)],
  products: [.library(name: "CrocheRuntime", targets: ["CrocheRuntime"])],
  targets: [.binaryTarget(name: "croche_ffiFFI", url: "https://maven.croche.ai/swift/0.5.5/CrocheRuntime.xcframework.zip", checksum: "54eb5791ef1ce7f8426d64cd4b087e6a5317a86b3528c3189d464eaf49c3b74f"),
            .target(name: "CrocheFFI", dependencies: ["croche_ffiFFI"], swiftSettings: [.swiftLanguageMode(.v5)]),
            .target(name: "CrocheRuntime", dependencies: ["CrocheFFI"])])
