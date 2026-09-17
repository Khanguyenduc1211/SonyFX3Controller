# Sony VERIC packet notes (CrSDK 2.02 binary-derived)

These are implementation facts recovered from Sony `libmonitor_protocol.dylib`; they are not public Sony wire-protocol documentation.

- `PacketAnalyser.doAnalyse` rejects packets shorter than `0x40` bytes.
- Packet bytes `0...4` must be ASCII `VERIC`.
- After parsing the header, Sony updates its `PacketDataInfo` pair by `{+64, -64}`. The x86_64 literal used by `paddd` is `40 00 00 00 c0 ff ff ff`, proving a 64-byte transport header is stripped before media/FEC processing.
- Multi-byte fields decoded by the header parser are network/big-endian.
- Confirmed byte accesses: 5, 6, 7, 8...11, 12...15, 16, 17, 18...19, 20...23, 24...25, 26...27, 32...39, 40...47, 56, 57 and 58.
- Field semantics are deliberately not named until the corresponding Kotlin object members are mapped. `SonyMonitoringReceiver.hpp` therefore exposes neutral `fieldXX` names rather than invented protocol terminology.

The reassembled JPEG media-slice parser (`RestoreData.sliceJpegLiveViewImage`) reads two big-endian 32-bit values from the beginning of a completed media slice. The first is range-checked to be at least `0x10` and within the slice; the second is also range-checked before copying the image range. We have not assigned semantic names to those fields yet.
