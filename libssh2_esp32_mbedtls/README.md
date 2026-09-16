# libssh2 ESP32 mbedTLS port

Source basis: the user-supplied `libssh2.zip` from Sony CrSDK 2.02.00 open-source bundle.
Upstream libssh2 version in that archive: 1.10.0.

Target baseline:
- Arduino-ESP32 3.3.11
- ESP-IDF 5.5.x
- ESP32-S3
- ESP-IDF bundled mbedTLS

This package:
- selects `LIBSSH2_MBEDTLS`
- provides an Arduino-friendly `libssh2_config.h`
- patches the libssh2 1.10.0 mbedTLS backend for mbedTLS 3.x API/private-member changes
- does not include OpenSSL, WinCNG, or libgcrypt backends

Install by extracting this folder under:
`Documents/Arduino/libraries/libssh2_esp32_mbedtls/`

Then restart Arduino IDE and compile the SonyController sketch.

The application still performs Sony camera-specific transport separately.


## esp32.2 fixes
- fixes mbedTLS 3.x RSA private-member access for DP/DQ/QP
- disables Blowfish/RC4 when those cipher modules are absent from ESP-IDF mbedTLS
- replaces removed `mbedtls_pk_load_file()` with stdio loading for the optional ECDSA key-file path
