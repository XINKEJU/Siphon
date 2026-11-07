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
        Sources/Siphon/Engines/Shared/NetFailure.swift
        Sources/Siphon/Engines/Shared/SegmentAssembler.swift
        Sources/Siphon/Managers/SpeedLimitController.swift
        Sources/Siphon/Protocols/NetRC.swift
        Sources/Siphon/Protocols/CredentialScope.swift
        Sources/Siphon/Engines/HLS/HLSParser.swift
        Sources/Siphon/Engines/DASH/DASHMPDParser.swift)
# HTTPDownloadEngine pulls in PAC/proxy routing and the per-host override store.
HTTP_EXTRA=(Sources/Siphon/Engines/Shared/NetFailure.swift
            Sources/Siphon/Protocols/PACResolver.swift
            Sources/Siphon/Protocols/ProxyRouter.swift
            Sources/Siphon/Protocols/PerHostSettings.swift
            Sources/Siphon/Protocols/NetRC.swift
            Sources/Siphon/Protocols/CredentialScope.swift
            Sources/Siphon/Engines/NativeHTTP/MirrorSelector.swift
            Sources/Siphon/Engines/NativeHTTP/HostHealthStore.swift
            Sources/Siphon/Engines/NativeHTTP/NetworkInterfaces.swift
            Sources/Siphon/Protocols/ProtocolSettings.swift
            Sources/Siphon/Managers/Keychain.swift
            Sources/Siphon/Protocols/S3Signer.swift
            Sources/Siphon/Engines/Shared/ExternalRunner.swift
            Sources/Siphon/Engines/Shared/ChecksumVerifier.swift
            Sources/Siphon/Engines/Shared/DiskSpaceGuard.swift
            Sources/Siphon/Engines/NativeHTTP/HTTPDownloadEngine.swift)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; kill "${SERVER_PID:-}" "${SERVER2_PID:-}" "${SERVER3_PID:-}" \
      "${SERVER4_PID:-}" "${ED2K_PID:-}" 2>/dev/null || true' EXIT

echo "== 1/22 swift build =="
swift build

echo "== 2/22 MD4 / eD2K / link vectors =="
swiftc -o "$TMP/vectors" Tests/VectorTests/main.swift "${MODELS[@]}" "${ED2K[@]}"
"$TMP/vectors"

echo "== 3/22 HLS / DASH parsers =="
swiftc -o "$TMP/parsers" Tests/ParserTests/main.swift "${MODELS[@]}" "${SHARED[@]}"
"$TMP/parsers"

echo "== 4/22 concurrent ordered segment assembly =="
( cd Tests/fixtures && exec python3 -m http.server 18765 --bind 127.0.0.1 ) \
    > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
# Wait for the fixture server without `sleep`-looping on the build.
for _ in $(seq 1 50); do
    if curl -sf -o /dev/null http://127.0.0.1:18765/media.m3u8; then break; fi
    python3 -c 'import time; time.sleep(0.1)'
done
# -parse-as-library: this test uses an @main async entry point (a file named
# main.swift is otherwise treated as a top-level script).
swiftc -parse-as-library -o "$TMP/segments" Tests/SegmentTests/main.swift "${MODELS[@]}" "${SHARED[@]}"
"$TMP/segments"

echo "== 4b/29 segmented resume sidecar (fingerprint + skip) =="
# Reuses the :18765 fixture server started above.
swiftc -parse-as-library -o "$TMP/resume-sidecar" Tests/ResumeTests/main.swift \
    "${MODELS[@]}" "${SHARED[@]}"
"$TMP/resume-sidecar"

KEYCHAIN=(Sources/Siphon/Managers/Keychain.swift
          Sources/Siphon/Managers/LocalAuthToken.swift)

echo "== 5/22 real aria2 JSON-RPC download (skipped if aria2c absent) =="
if command -v aria2c >/dev/null 2>&1; then
    ( cd Tests/fixtures-aria2 && exec python3 -m http.server 18766 --bind 127.0.0.1 ) \
        > "$TMP/server2.log" 2>&1 &
    SERVER2_PID=$!
    trap 'rm -rf "$TMP"; kill "${SERVER_PID:-}" "${SERVER2_PID:-}" "${SERVER3_PID:-}" 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do
        if curl -sf -o /dev/null http://127.0.0.1:18766/file.bin; then break; fi
        python3 -c 'import time; time.sleep(0.1)'
    done
    swiftc -o "$TMP/aria2e2e" Tests/Aria2RPCTests/main.swift \
        "${MODELS[@]}" Sources/Siphon/Engines/Engine.swift \
        "${KEYCHAIN[@]}" \
        Sources/Siphon/Engines/Shared/NetFailure.swift \
        Sources/Siphon/Engines/Shared/ChecksumVerifier.swift \
        Sources/Siphon/Engines/Aria2/Aria2Bootstrap.swift \
        Sources/Siphon/Engines/Aria2/Aria2RPC.swift \
        Sources/Siphon/Engines/Aria2/Aria2Engine.swift
    SIPHON_ARIA2_RPC_SECRET="verify-only-aria2-secret" "$TMP/aria2e2e"
    kill "$SERVER2_PID" 2>/dev/null || true
else
    echo "SKIP  aria2c not installed (brew install aria2 to enable)"
fi

echo "== 6/22 protocol matrix: detection, vendor links, playlists, SigV4, normalization, engine E2E =="
# Fixture server on :18765 is still running from step 4 and serves seg0.ts.
PROTOCOL_SOURCES=(
    Sources/Siphon/Engines/Engine.swift
    "${MODELS[@]}"
    Sources/Siphon/Protocols/SpecialLinks.swift
    Sources/Siphon/Protocols/PlaylistImporter.swift
    Sources/Siphon/Protocols/NetRC.swift
    Sources/Siphon/Protocols/S3Signer.swift
    Sources/Siphon/Protocols/ProtocolSettings.swift
    "${KEYCHAIN[@]}"
    Sources/Siphon/Protocols/URINormalizer.swift
    Sources/Siphon/Protocols/MetalinkParser.swift
    Sources/Siphon/Protocols/WebDAVLister.swift
    Sources/Siphon/Protocols/FTPDirectoryLister.swift
    Sources/Siphon/Engines/HLS/HLSParser.swift
    Sources/Siphon/Engines/Shared/ExternalRunner.swift
    Sources/Siphon/Engines/Shared/NetFailure.swift
    Sources/Siphon/Engines/Shared/ChecksumVerifier.swift
    Sources/Siphon/Managers/SpeedLimitController.swift
    Sources/Siphon/Engines/Local/LocalEngine.swift
    Sources/Siphon/Engines/External/CurlEngine.swift
    Sources/Siphon/Engines/Aria2/Aria2Bootstrap.swift
    Sources/Siphon/Engines/Aria2/Aria2RPC.swift
    Sources/Siphon/Engines/Aria2/Aria2Engine.swift
)
swiftc -o "$TMP/protocols" Tests/ProtocolTests/main.swift "${PROTOCOL_SOURCES[@]}"
"$TMP/protocols"

echo "== 7/22 ED2K engine (resume destination regression) =="
swiftc -o "$TMP/ed2kengine" Tests/ED2KTests/main.swift \
    Sources/Siphon/Models/*.swift \
    Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    Sources/Siphon/Engines/Shared/NetFailure.swift \
    Sources/Siphon/Engines/Shared/DiskSpaceGuard.swift \
    Sources/Siphon/Engines/ED2K/*.swift
"$TMP/ed2kengine"

echo "== 8/22 NativeMessagingServer (split-request regression) =="
swiftc -framework Network -o "$TMP/nativemsg" \
    Tests/NativeMessagingTests/main.swift \
    Sources/Siphon/BrowserExtension/NativeMessagingServer.swift \
    "${KEYCHAIN[@]}"
"$TMP/nativemsg"

echo "== 9/22 native HTTP download engine (no external tools) =="
mkdir -p Tests/fixtures-http
# Deterministic ~5 MiB fixture so the test can verify exact byte equality.
python3 - <<'PY'
import os
p = "Tests/fixtures-http/big.bin"
if not os.path.exists(p):
    n = 5_000_000
    s = 123456789
    with open(p, "wb") as f:
        for _ in range(0, n, 65536):
            chunk = bytearray(min(65536, n - _))
            for j in range(len(chunk)):
                s = (1103515245 * s + 12345) & 0x7fffffff
                chunk[j] = s & 0xff
            f.write(chunk)
PY

# Range-capable fixture server on :18767 (python -m http.server does not honour
# Range, so we serve a tiny handler that does).
cat > "$TMP/range_server.py" <<'PY'
import http.server, socketserver, os, re
ROOT = os.path.join(os.getcwd(), "Tests/fixtures-http")
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = os.path.join(ROOT, self.path.lstrip("/"))
        if not os.path.isfile(path):
            self.send_error(404); return
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d+)-(\d*)", rng)
            start = int(m.group(1)); end = size - 1
            if m.group(2): end = min(int(m.group(2)), size - 1)
            with open(path, "rb") as f:
                f.seek(start); data = f.read(end - start + 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers(); self.wfile.write(data)
        else:
            with open(path, "rb") as f: data = f.read()
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(size))
            self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 18767), H) as s:
    s.serve_forever()
PY
python3 "$TMP/range_server.py" > "$TMP/range_server.log" 2>&1 &
SERVER3_PID=$!
for _ in $(seq 1 50); do
    if curl -sf -o /dev/null http://127.0.0.1:18767/big.bin; then break; fi
    python3 -c 'import time; time.sleep(0.1)'
done
swiftc -framework SystemConfiguration -framework JavaScriptCore -o "$TMP/nativehttp" Tests/NativeHTTPTests/main.swift \
    "${MODELS[@]}" Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    "${HTTP_EXTRA[@]}"
"$TMP/nativehttp"
kill "$SERVER3_PID" 2>/dev/null || true

echo "== 10/22 native eD2K transport (real wire protocol E2E) =="
# Deterministic multi-block fixture (>2 x 180 KiB + short tail); both the Swift
# test and the independent Python peer read the same file.
FIXTURE=Tests/fixtures-ed2k/fixture.bin
mkdir -p Tests/fixtures-ed2k
if [[ ! -f "$FIXTURE" ]]; then
    python3 - "$FIXTURE" <<'PY'
import sys
seed = 0x9E3779B97F4A7C15
size = 180*1024*2 + 12345
with open(sys.argv[1], "wb") as f:
    for _ in range(size):
        seed = (seed * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        f.write(bytes([(seed >> 33) & 0xFF]))
PY
fi
python3 Tests/fixtures-ed2k/ed2k_peer.py "$FIXTURE" 18770 > "$TMP/ed2k_peer.log" 2>&1 &
ED2K_PID=$!
for _ in $(seq 1 50); do
    if python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',18770))==0 else 1)" 2>/dev/null; then break; fi
    python3 -c 'import time; time.sleep(0.1)'
done
swiftc -o "$TMP/ed2knative" Tests/ED2KNativeTests/main.swift \
    Sources/Siphon/Models/*.swift \
    Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    Sources/Siphon/Engines/Shared/NetFailure.swift \
    Sources/Siphon/Engines/Shared/DiskSpaceGuard.swift \
    Sources/Siphon/Engines/ED2K/*.swift
"$TMP/ed2knative"
kill "$ED2K_PID" 2>/dev/null || true

echo "== 11/22 LocalEngine + CurlEngine transport smoke =="
( cd Tests/fixtures-http && exec python3 -m http.server 18773 --bind 127.0.0.1 ) \
    > "$TMP/server4.log" 2>&1 &
SERVER4_PID=$!
for _ in $(seq 1 50); do
    if curl -sf -o /dev/null http://127.0.0.1:18773/big.bin; then break; fi
    python3 -c 'import time; time.sleep(0.1)'
done
SMOKE=(Sources/Siphon/Engines/Engine.swift
       "${MODELS[@]}"
       Sources/Siphon/Protocols/NetRC.swift
       Sources/Siphon/Protocols/S3Signer.swift
       Sources/Siphon/Protocols/ProtocolSettings.swift
       "${KEYCHAIN[@]}"
       Sources/Siphon/Engines/Shared/ExternalRunner.swift
       Sources/Siphon/Managers/SpeedLimitController.swift
       Sources/Siphon/Engines/Local/LocalEngine.swift
       Sources/Siphon/Engines/External/CurlEngine.swift)
swiftc -o "$TMP/smoke" Tests/TransferSmokeTests/main.swift "${SMOKE[@]}"
"$TMP/smoke"
kill "$SERVER4_PID" 2>/dev/null || true

echo "== 12/22 Info.plist scheme registration matches URISchemes.registered =="
python3 - <<'PY'
import plistlib, re, sys
p = plistlib.load(open('Resources/Info.plist', 'rb'))
plist_schemes = sorted({s for e in p['CFBundleURLTypes'] for s in e['CFBundleURLSchemes']})
src = open('Sources/Siphon/Models/Protocols.swift').read()
m = re.search(r'public static let registered: \[String\] = \[(.*?)\]', src, re.S)
if not m:
    sys.exit('URISchemes.registered not found in Protocols.swift')
swift_schemes = sorted(set(re.findall(r'"([a-z0-9]+)"', m.group(1))))
missing_in_plist = set(swift_schemes) - set(plist_schemes)
missing_in_swift = set(plist_schemes) - set(swift_schemes)
if missing_in_plist or missing_in_swift:
    sys.exit(f'scheme mismatch: plist-only={sorted(missing_in_swift)} '
             f'swift-only={sorted(missing_in_plist)}')
print(f'OK  {len(swift_schemes)} schemes registered in both Info.plist and URISchemes.registered')
PY

echo "== 13/22 native HTTP resume suite (.part publish, ETag pinning, checksum) =="
swiftc -framework SystemConfiguration -framework JavaScriptCore -o "$TMP/resume" Tests/NativeHTTPResumeTests/main.swift \
    "${MODELS[@]}" Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    "${HTTP_EXTRA[@]}"
"$TMP/resume"

echo "== 14/22 yt-dlp resolver (stub binary, offline) =="
swiftc -o "$TMP/ytdlp" Tests/YtDlpTests/main.swift \
    Sources/Siphon/Protocols/YtDlpResolver.swift \
    Sources/Siphon/Engines/Shared/ExternalRunner.swift "${MODELS[@]}"
"$TMP/ytdlp"

echo "== 15/22 JavaScriptCore plugin host (sandbox + CRLF guard) =="
swiftc -framework JavaScriptCore -o "$TMP/plugins" \
    Tests/PluginHostTests/main.swift Sources/Siphon/Plugins/PluginHost.swift
"$TMP/plugins"

echo "== 16/22 RSS/Atom feed parsing + guid diffing (loopback) =="
swiftc -framework Network -o "$TMP/feeds" \
    Tests/RSSFeedTests/main.swift Sources/Siphon/RSS/FeedManager.swift
"$TMP/feeds"

echo "== 17/22 FTP directory listing (MLSD/LIST/NLST parser) =="
swiftc -o "$TMP/ftplist" Tests/FTPListerTests/main.swift \
    Sources/Siphon/Models/*.swift \
    Sources/Siphon/Protocols/FTPDirectoryLister.swift \
    Sources/Siphon/Protocols/ProtocolSettings.swift \
    "${KEYCHAIN[@]}" \
    Sources/Siphon/Protocols/S3Signer.swift \
    Sources/Siphon/Engines/Shared/ExternalRunner.swift
"$TMP/ftplist"

echo "== 18/22 turtle three-tier limiter (off/on/auto window fold) =="
swiftc -framework AppKit -o "$TMP/turtle" Tests/TurtleTests/main.swift \
    Sources/Siphon/Managers/TaskPolicy.swift
"$TMP/turtle"

echo "== 19/22 per-task token-bucket throttler =="
swiftc -framework SystemConfiguration -framework JavaScriptCore -parse-as-library -o "$TMP/throttle" Tests/ThrottlerTests/main.swift \
    "${MODELS[@]}" Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    "${HTTP_EXTRA[@]}"
"$TMP/throttle"

echo "== 20/22 PAC resolver (parse + JavaScriptCore evaluation) =="
swiftc -framework JavaScriptCore -o "$TMP/pac" \
    Tests/PACResolverTests/main.swift Sources/Siphon/Protocols/PACResolver.swift
"$TMP/pac"

echo "== 21/22 MCP JSON-RPC + webhook payload =="
swiftc -framework Network -o "$TMP/mcp" \
    Tests/MCPTests/main.swift \
    Sources/Siphon/BrowserExtension/MCPServer.swift \
    Sources/Siphon/Managers/WebhookManager.swift \
    "${KEYCHAIN[@]}"
"$TMP/mcp"

echo "== 22/22 loopback API token (REST + MCP auth, no CORS) =="
swiftc -framework Network -o "$TMP/localauth" \
    Tests/LocalAuthTests/main.swift \
    Sources/Siphon/BrowserExtension/NativeMessagingServer.swift \
    Sources/Siphon/BrowserExtension/MCPServer.swift \
    "${KEYCHAIN[@]}"
"$TMP/localauth"

echo "== 22/22 credential scoping (site/origin filter, redirect guard, segment assembler) =="
swiftc -parse-as-library -o "$TMP/credscope" Tests/CredentialScopeTests/main.swift \
    "${MODELS[@]}" "${SHARED[@]}"
"$TMP/credscope"

echo "== 23/23 Metalink v3/v4 + WebDAV PROPFIND parsers (offline) =="
swiftc -o "$TMP/metalink" Tests/MetalinkTests/main.swift Sources/Siphon/Protocols/MetalinkParser.swift
"$TMP/metalink"
swiftc -o "$TMP/webdav" Tests/WebDAVTests/main.swift Sources/Siphon/Protocols/WebDAVLister.swift
"$TMP/webdav"

echo "== 24/24 self-update feed parsing + version compare + SHA-256 (offline) =="
swiftc -framework AppKit -o "$TMP/updater" Tests/UpdateCheckerTests/main.swift \
    Sources/Siphon/Managers/UpdateChecker.swift
"$TMP/updater"

echo "== 25/25 netrc parsing + host lookup (offline) =="
swiftc -o "$TMP/netrc" Tests/NetRCTests/main.swift Sources/Siphon/Protocols/NetRC.swift
"$TMP/netrc"

echo "== 26/27 streaming preview server (Range + live watermark) =="
swiftc -framework Network -o "$TMP/preview" \
    Tests/PreviewServerTests/main.swift \
    Sources/Siphon/Managers/PreviewServer.swift
"$TMP/preview"

echo "== 27/28 native messaging framing (4-byte LE length + caps) =="
swiftc -o "$TMP/nmframing" Tests/NMFramingTests/main.swift \
    Sources/SiphonBridge/NativeMessagingFraming.swift
"$TMP/nmframing"

echo "== 28/28 MDXP JSON-RPC bridge (dispatch + error codes) =="
swiftc -o "$TMP/mdxp" Tests/MDXPBridgeTests/main.swift \
    Sources/Siphon/Managers/MDXPBridge.swift
"$TMP/mdxp"

# Heavy and GUI-dependent: launches the real app, SIGKILLs it mid-download and
# relaunches it. Opt-in so the normal suite stays headless.
if [[ "${SIPHON_GUI_RESTART_E2E:-0}" == "1" ]]; then
    echo "== 29/29 GUI restart E2E (A1 auto-resume) =="
    "$ROOT/scripts/verify-restart.sh"
fi

echo
echo "ALL CHECKS PASSED"