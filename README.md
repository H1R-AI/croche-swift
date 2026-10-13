# Croche Runtime for Swift

Swift 6 and iOS 15 or later are required. Add this package's release tag with
Swift Package Manager and select the `CrocheRuntime` library product.

```swift
import CrocheRuntime
```

The package includes the Swift SDK and generated bindings. Swift Package Manager
downloads the matching Core XCFramework and verifies its SHA-256 checksum.

Release maintainers: the versioned archive and package git tag must not exist yet.
The caller must check the tag before packaging and publishing:

```sh
git ls-remote --tags "$PACKAGE_REPO_URL" "refs/tags/$VERSION" "refs/tags/$VERSION^{}"
```

Require a successful command with no output. The packaging script requires HTTP
404 for the archive URL; an existing archive or a network error refuses the build.
Published versions are immutable. Never overwrite a tag or archive; fixes require
a new version.
