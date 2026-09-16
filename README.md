# Sony FX3 / FX30 iPhone Controller

Native UIKit controller for Sony FX3/FX30 remote shooting over the camera's documented SSH-protected PTP/IP path.

## Safety and connection model

The app does **not** open a direct TCP connection to port 15740. Its only initial connection is SSH to the camera on port 22:

```text
iPhone → SSH :22 → verify SHA-256 host fingerprint → password auth
       → command SSH direct-tcpip channel: localhost:15740
       → event SSH direct-tcpip channel: localhost:15740 → PTP/IP / Sony PTP3
```

On the first connection, the app displays the SHA-256 fingerprint and does not send credentials until the user explicitly trusts it. The fingerprint is tied to the camera IP and username. Changing either removes trust; an unexpected fingerprint mismatch blocks authentication. Passwords are stored only in iOS Keychain.

## Features implemented

- Serial background camera queue; UIKit updates occur on the main thread.
- PTP/IP OpenSession, Sony SDIO connect stages, host-PC mode, property refresh and PTP3 property parser.
- Parser supports all signed/unsigned scalar widths, strings, arrays, ranges, and Sony's two independent enumeration lists in `0x9209`.
- Dynamic control, focus, and record-format pickers populated by the camera's enabled/writable properties.
- Record state `D21D` handling (`0` stopped, `1` recording, `2` unable), local timer, relative signed-Int16 MF pull, and AF-hold.
- Format settings use `D241`, `D286`, `D242`, `D109`, `D0D0`, and `D0D1`; they lock while recording.

## Project layout

| Path | Purpose |
|---|---|
| `App/` | App lifecycle, network privacy declaration, encrypted profile/password handling |
| `UI/` | UIKit CONTROL, FOCUS, FORMAT, connection and dynamic picker screens |
| `CameraCore/` | SSH transport, PTP/IP session, PTP3 parser and camera state |
| `Bridge/` | Objective-C++ bridge between Swift and the C++ camera core |
| `ThirdParty/libssh2/` | Generated iphoneos arm64 libssh2/mbedTLS artifacts |
| `.github/workflows/build-ios.yml` | macOS CI build and IPA artifact workflow |

Read [BUILD_IOS.md](BUILD_IOS.md) to build or publish, and [INSTALL_IPA.md](INSTALL_IPA.md) for installation options.

## Hardware validation status

The project has deterministic parser tests that run in GitHub Actions. Actual SSH/firmware compatibility, supported property values, and camera behavior still require testing against the user's FX3/FX30. The UI deliberately uses values the camera reports instead of assuming a fixed firmware table.
