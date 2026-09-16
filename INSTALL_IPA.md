# Installing on an iPhone

The GitHub Actions artifact is intentionally an **unsigned archive-only IPA**. It is useful for inspecting the `iphoneos arm64` build but cannot be launched on stock iOS without signing.

## Normal Apple signing

1. On a Mac, open `SonyFX3Controller.xcodeproj` in Xcode.
2. Select target **SonyFX3Controller** → **Signing & Capabilities**.
3. Set a unique Bundle Identifier and select your Apple Development Team.
4. Connect the iPhone, choose it as the run destination, then press Run.

For distribution outside a development device, use your own Apple Developer account and the appropriate Xcode archive/export method.

## Alternative environments

If you use a third-party installer environment such as TrollStore, export/sign using that environment's documented workflow. This repository does not include an installer, entitlement bypass, certificate, or signing identity.

## Camera setup reminder

Enable the camera's supported PC Remote / remote shooting mode and configure its SSH/access authentication on the camera. On first use, compare the fingerprint shown by the app with the camera/network setup before tapping **Trust and connect**. Do not accept a changed fingerprint blindly.
