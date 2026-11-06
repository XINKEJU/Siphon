#!/usr/bin/env bash
# Verifies the core algorithms and the whole package build.
# Usage: ./scripts/verify.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MODELS=(Sources/Siphon/Models/*.swift)
ED2K=(Sources/Siphon/Engines/ED2K/MD4.swift
      Sources/Siphon/Engines/ED2K/ED2KHash.swift
      Sources/Siphon/Engines/ED2K/ED2KURI.swift)
SHARED=(Sources/Siphon/Engines/Engine.swift
        Sources/Siphon/Engines/Shared/SegmentAssembler.swift
        Sources/Siphon/Managers/SpeedLimitController.swift
        Sources/Siphon/Engines/HLS/HLSParser.swift
        Sources/Siphon/Engines/DASH/DASHMPDParser.swift)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill "${SERVER_PID:-}" 2>/dev/null || true' EXIT

echo "== 1/4 swift build =="
swift build

echo "== 2/4 MD4 / eD2K / link vectors =="
swiftc -o "$TMP/vectors" Tests/VectorTests/main.swift "${MODELS[@]}" "${ED2K[@]}"
"$TMP/vectors"

echo "== 3/4 HLS / DASH parsers =="
swiftc -o "$TMP/parsers" Tests/ParserTests/main.swift "${MODELS[@]}" "${SHARED[@]}"
"$TMP/parsers"

echo "== 4/5 concurrent ordered segment assembly =="
( cd Tests/fixtures && exec python3 -m http.server 18765 --bind 127.0.0.1 ) \
    > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
# Wait for the fixture server without `sleep`-looping on the build.
for _ in $(seq 1 50); do
    if curl -sf -o /dev/null http://127.0.0.1:18765/media.m3u8; then break; fi
    python3 -c 'import time; time.sleep(0.1)'
done
swiftc -o "$TMP/segments" Tests/SegmentTests/main.swift "${MODELS[@]}" "${SHARED[@]}"
"$TMP/segments"

echo "== 5/5 real aria2 JSON-RPC download (skipped if aria2c absent) =="
if command -v aria2c >/dev/null 2>&1; then
    ( cd Tests/fixtures-aria2 && exec python3 -m http.server 18766 --bind 127.0.0.1 ) \
        > "$TMP/server2.log" 2>&1 &
    SERVER2_PID=$!
    trap 'rm -rf "$TMP"; kill "${SERVER_PID:-}" "${SERVER2_PID:-}" 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do
        if curl -sf -o /dev/null http://127.0.0.1:18766/file.bin; then break; fi
        python3 -c 'import time; time.sleep(0.1)'
    done
    swiftc -o "$TMP/aria2e2e" Tests/Aria2RPCTests/main.swift \
        Sources/Siphon/Engines/Aria2/Aria2Bootstrap.swift \
        Sources/Siphon/Engines/Aria2/Aria2RPC.swift
    "$TMP/aria2e2e"
    kill "$SERVER2_PID" 2>/dev/null || true
else
    echo "SKIP  aria2c not installed (brew install aria2 to enable)"
fi

echo
echo "ALL CHECKS PASSED"
