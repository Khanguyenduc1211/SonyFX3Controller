# Sony Camera Remote SDK 2.02 Monitoring reverse notes

This document separates facts established from Sony's SDK/API from private wire behavior that still requires binary/capture verification.

## Established

- Public flow: configure monitoring delivery, then start/stop monitoring.
- Public delivery configuration includes receiver IP, down-time, video/meta ports, image quality level and transport selection.
- `videoPort == 0` / `metaPort == 0` select the SDK defaults; the observed defaults are 55001 and 55005.
- Public Monitoring operation semantics: Stop = 0, Start = 1.
- Inspection of Sony `Cr_PTP_IP` 2.02 establishes a vendor PTP operation at `0x9230` for Monitoring control.
- The adapter sends one UINT32 operation parameter and uses a PTP Data-Out phase.
- `libmonitor_protocol` contains Sony's receive/dispatch/analyse path, VERIC-related framing, FEC/recovery and data-decryption components. Therefore the UDP path must not be implemented as naive JPEG-marker scanning.

## Not established yet — do not guess

- Exact byte serialization of the `0x9230` Data-Out dataset for Start and Stop.
- Whether all configuration is serialized in that dataset or some values are negotiated separately.
- VERIC packet header byte layout and endianness.
- Frame/fragment sequence fields and completion rules.
- FEC group layout and recovery algorithm parameters.
- Encryption/session-key/IV derivation, if active for the selected FX3 transport.
- Metadata-channel packet layout.

## Integration rule

Until the missing wire fields above have test vectors, the app must keep the existing `GetObject(0xFFFFC002)` Live View path as the functional fallback. `SonyMonitoring.hpp` intentionally refuses to build a Start request instead of emitting speculative camera commands.

The push receiver architecture will use a latest-complete-frame mailbox so stale frames are dropped rather than decoded in order.
