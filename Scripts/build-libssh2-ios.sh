#!/bin/bash
set -euo pipefail

# Builds fixed upstream mbedTLS + libssh2 for iphoneos arm64.  iOS uses Apple's
# system Security framework through mbedTLS; OpenSSL is intentionally not used.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/ThirdParty/source-cache"
OUT="$ROOT/ThirdParty/libssh2"
BUILD="$ROOT/build/thirdparty"
LIBSSH2_TAG="libssh2-1.11.1"
MBEDTLS_TAG="v3.6.2"

mkdir -p "$CACHE" "$OUT/include" "$OUT/lib" "$BUILD"
if [ ! -d "$CACHE/libssh2/.git" ]; then git clone --depth 1 --branch "$LIBSSH2_TAG" https://github.com/libssh2/libssh2.git "$CACHE/libssh2"; fi
if [ ! -d "$CACHE/mbedtls/.git" ]; then git clone --depth 1 --branch "$MBEDTLS_TAG" https://github.com/Mbed-TLS/mbedtls.git "$CACHE/mbedtls"; fi

IOS=(-DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_BUILD_TYPE=Release)
cmake -S "$CACHE/mbedtls" -B "$BUILD/mbedtls" "${IOS[@]}" -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF -DCMAKE_INSTALL_PREFIX="$BUILD/prefix"
cmake --build "$BUILD/mbedtls" --config Release --parallel 3
cmake --install "$BUILD/mbedtls" --config Release
cmake -S "$CACHE/libssh2" -B "$BUILD/libssh2" "${IOS[@]}" -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DCRYPTO_BACKEND=mbedTLS -DMBEDTLS_ROOT_DIR="$BUILD/prefix"
cmake --build "$BUILD/libssh2" --config Release --parallel 3

rm -rf "$OUT/include" "$OUT/lib"; mkdir -p "$OUT/include" "$OUT/lib"
cp "$CACHE/libssh2/include/libssh2.h" "$OUT/include/"
find "$BUILD/libssh2" -name 'libssh2.a' -exec cp {} "$OUT/lib/" \;
find "$BUILD/mbedtls" -name 'libmbed*.a' -exec cp {} "$OUT/lib/" \;
test -f "$OUT/lib/libssh2.a"
echo "Built iphoneos arm64 static libraries in $OUT/lib"
