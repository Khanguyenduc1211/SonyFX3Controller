#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/tests"
clang++ -std=c++17 -Wall -Wextra -I"$ROOT/CameraCore" "$ROOT/Tests/SonyProtocolTests.cpp" -o "$ROOT/build/tests/SonyProtocolTests"
"$ROOT/build/tests/SonyProtocolTests"
