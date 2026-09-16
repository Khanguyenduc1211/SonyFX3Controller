#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Release-iphoneos/SonyFX3Controller.app"
OUT="$ROOT/build/ipa"
test -d "$APP"
rm -rf "$OUT"; mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && /usr/bin/zip -qry "$ROOT/build/SonyFX3Controller-unsigned.ipa" Payload)
echo "Created archive-only unsigned IPA: build/SonyFX3Controller-unsigned.ipa"
