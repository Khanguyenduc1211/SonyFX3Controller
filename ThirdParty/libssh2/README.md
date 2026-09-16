# libssh2 for iOS

Do not add a macOS or simulator library here. `Scripts/build-libssh2-ios.sh` downloads pinned upstream sources and builds static `arm64` **iphoneos** libraries using mbedTLS. The build intentionally does not use OpenSSL.

Generated `include/` and `lib/` contents are ignored by Git and are created by GitHub Actions before Xcode builds the app.
