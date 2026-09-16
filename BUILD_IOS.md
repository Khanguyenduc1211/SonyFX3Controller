# Building for iphoneos arm64

## GitHub Actions (works from Windows)

1. Create an empty GitHub repository named `SonyFX3Controller`.
2. From this project directory, initialize/push using your own GitHub account name:

```powershell
git init
git add .
git commit -m "Initial iOS FX3 controller"
git branch -M main
git remote add origin https://github.com/USERNAME/SonyFX3Controller.git
git push -u origin main
```

3. Open **Actions** → **build-ios** → **Run workflow**. The macOS runner runs parser tests, builds mbedTLS/libssh2 for `iphoneos arm64`, then builds `SonyFX3Controller.app` with code signing disabled and uploads an artifact.

The unsigned output proves the project builds for a physical iPhone CPU. It cannot be installed as-is; see `INSTALL_IPA.md`.

## Xcode build on a Mac

```bash
bash Scripts/build-libssh2-ios.sh
xcodebuild -project SonyFX3Controller.xcodeproj -scheme SonyFX3Controller \
  -configuration Debug -sdk iphoneos ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build
```

For a device install, set a unique Bundle Identifier and your Apple Development Team in Xcode's **Signing & Capabilities**, then build/run on the connected iPhone. Do not commit a personal Team ID.

## Tests

`Tests/run-core-tests.sh` exercises little-endian encoding, signed `Int16` focus deltas, formatting, and the two-list Sony enumeration dataset. It is deliberately independent of a camera so CI can validate it on macOS.
