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
        Sources/Siphon/Engines/Shared/DiskSpaceGuard.swift
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

echo "== [1/33] swift build =="
swift build

echo "== [2/33] MD4 / eD2K / link vectors =="
swiftc -o "$TMP/vectors" Tests/VectorTests/main.swift "${MODELS[@]}" "${ED2K[@]}"
"$TMP/vectors"

echo "== [3/33] HLS / DASH parsers =="
swiftc -o "$TMP/parsers" Tests/ParserTests/main.swift "${MODELS[@]}" "${SHARED[@]}"
"$TMP/parsers"

echo "== [4/33] concurrent ordered segment assembly =="
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

echo "== [5/33] segmented resume sidecar (fingerprint + skip) =="
# Reuses the :18765 fixture server started above.
swiftc -parse-as-library -o "$TMP/resume-sidecar" Tests/ResumeTests/main.swift \
    "${MODELS[@]}" "${SHARED[@]}"
"$TMP/resume-sidecar"

KEYCHAIN=(Sources/Siphon/Managers/Keychain.swift
          Sources/Siphon/Managers/LocalAuthToken.swift
          Sources/SiphonBridge/LocalAuthBootstrap.swift)

echo "== [6/33] real aria2 JSON-RPC download (skipped if aria2c absent) =="
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
        Sources/Siphon/Engines/Shared/DiskSpaceGuard.swift \
        Sources/Siphon/Engines/Shared/TorrentProbe.swift \
        Sources/Siphon/Engines/Aria2/Aria2Bootstrap.swift \
        Sources/Siphon/Engines/Aria2/Aria2RPC.swift \
        Sources/Siphon/Engines/Aria2/Aria2Engine.swift
    SIPHON_ARIA2_RPC_SECRET="verify-only-aria2-secret" "$TMP/aria2e2e"
    kill "$SERVER2_PID" 2>/dev/null || true
else
    # CI sets SIPHON_REQUIRE_ARIA2=1: a missing aria2c must fail the job rather
    # than quietly skipping the only real JSON-RPC download test.
    if [[ "${SIPHON_REQUIRE_ARIA2:-0}" == "1" ]]; then
        echo "FAIL  aria2c is required (SIPHON_REQUIRE_ARIA2=1)" >&2
        exit 1
    fi
    echo "SKIP  aria2c not installed (brew install aria2 to enable)"
fi

echo "== [7/33] protocol matrix: detection, vendor links, playlists, SigV4, normalization, engine E2E =="
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
    Sources/Siphon/Engines/Shared/DiskSpaceGuard.swift
    Sources/Siphon/Engines/Shared/TorrentProbe.swift
    Sources/Siphon/Engines/Shared/CompletionSizePolicy.swift
    Sources/Siphon/Managers/SpeedLimitController.swift
    Sources/Siphon/Engines/Local/LocalEngine.swift
    Sources/Siphon/Engines/External/CurlEngine.swift
    Sources/Siphon/Engines/Aria2/Aria2Bootstrap.swift
    Sources/Siphon/Engines/Aria2/Aria2RPC.swift
    Sources/Siphon/Engines/Aria2/Aria2Engine.swift
)
swiftc -o "$TMP/protocols" Tests/ProtocolTests/main.swift "${PROTOCOL_SOURCES[@]}"
"$TMP/protocols"

echo "== [8/33] ED2K engine (resume destination regression) =="
swiftc -o "$TMP/ed2kengine" Tests/ED2KTests/main.swift \
    Sources/Siphon/Models/*.swift \
    Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    Sources/Siphon/Engines/Shared/NetFailure.swift \
    Sources/Siphon/Engines/Shared/DiskSpaceGuard.swift \
    Sources/Siphon/Engines/ED2K/*.swift
"$TMP/ed2kengine"

echo "== [9/33] NativeMessagingServer (split-request regression) =="
swiftc -framework Network -o "$TMP/nativemsg" \
    Tests/NativeMessagingTests/main.swift \
    Sources/Siphon/BrowserExtension/NativeMessagingServer.swift \
    Sources/Siphon/BrowserExtension/NativeMessagingHostInstaller.swift \
    "${KEYCHAIN[@]}"
"$TMP/nativemsg"

echo "== [10/33] native HTTP download engine (no external tools) =="
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

echo "== [11/33] native eD2K transport (real wire protocol E2E) =="
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

echo "== [12/33] LocalEngine + CurlEngine transport smoke =="
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
       Sources/Siphon/Engines/Shared/CompletionSizePolicy.swift
       Sources/Siphon/Managers/SpeedLimitController.swift
       Sources/Siphon/Engines/Local/LocalEngine.swift
       Sources/Siphon/Engines/External/CurlEngine.swift)
swiftc -o "$TMP/smoke" Tests/TransferSmokeTests/main.swift "${SMOKE[@]}"
"$TMP/smoke"
kill "$SERVER4_PID" 2>/dev/null || true

echo "== [13/33] Info.plist scheme registration matches URISchemes.registered =="
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

echo "== [14/33] native HTTP resume suite (.part publish, ETag pinning, checksum) =="
swiftc -framework SystemConfiguration -framework JavaScriptCore -o "$TMP/resume" Tests/NativeHTTPResumeTests/main.swift \
    "${MODELS[@]}" Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    "${HTTP_EXTRA[@]}"
"$TMP/resume"

echo "== [15/33] yt-dlp resolver (stub binary, offline) =="
swiftc -o "$TMP/ytdlp" Tests/YtDlpTests/main.swift \
    Sources/Siphon/Protocols/YtDlpResolver.swift \
    Sources/Siphon/Engines/Shared/ExternalRunner.swift "${MODELS[@]}"
"$TMP/ytdlp"

echo "== [16/33] JavaScriptCore plugin host (sandbox + CRLF guard) =="
swiftc -framework JavaScriptCore -o "$TMP/plugins" \
    Tests/PluginHostTests/main.swift Sources/Siphon/Plugins/PluginHost.swift
"$TMP/plugins"

echo "== [17/33] RSS/Atom feed parsing + guid diffing (loopback) =="
swiftc -framework Network -o "$TMP/feeds" \
    Tests/RSSFeedTests/main.swift Sources/Siphon/RSS/FeedManager.swift
"$TMP/feeds"

echo "== [18/33] FTP directory listing (MLSD/LIST/NLST parser) =="
swiftc -o "$TMP/ftplist" Tests/FTPListerTests/main.swift \
    Sources/Siphon/Models/*.swift \
    Sources/Siphon/Protocols/FTPDirectoryLister.swift \
    Sources/Siphon/Protocols/ProtocolSettings.swift \
    "${KEYCHAIN[@]}" \
    Sources/Siphon/Protocols/S3Signer.swift \
    Sources/Siphon/Engines/Shared/ExternalRunner.swift
"$TMP/ftplist"

echo "== [19/33] turtle three-tier limiter (off/on/auto window fold) =="
swiftc -framework AppKit -o "$TMP/turtle" Tests/TurtleTests/main.swift \
    Sources/Siphon/Managers/TaskPolicy.swift
"$TMP/turtle"

echo "== [20/33] per-task token-bucket throttler =="
swiftc -framework SystemConfiguration -framework JavaScriptCore -parse-as-library -o "$TMP/throttle" Tests/ThrottlerTests/main.swift \
    "${MODELS[@]}" Sources/Siphon/Engines/Engine.swift \
    Sources/Siphon/Managers/SpeedLimitController.swift \
    "${HTTP_EXTRA[@]}"
"$TMP/throttle"

echo "== [21/33] PAC resolver (parse + JavaScriptCore evaluation) =="
swiftc -framework JavaScriptCore -o "$TMP/pac" \
    Tests/PACResolverTests/main.swift Sources/Siphon/Protocols/PACResolver.swift
"$TMP/pac"

echo "== [22/33] MCP JSON-RPC + webhook payload =="
swiftc -framework Network -o "$TMP/mcp" \
    Tests/MCPTests/main.swift \
    Sources/Siphon/BrowserExtension/MCPServer.swift \
    Sources/Siphon/Managers/WebhookManager.swift \
    Sources/Siphon/Managers/WebhookPolicy.swift \
    "${KEYCHAIN[@]}"
"$TMP/mcp"

echo "== [23/33] loopback API token (REST + MCP auth, no CORS) =="
swiftc -framework Network -o "$TMP/localauth" \
    Tests/LocalAuthTests/main.swift \
    Sources/Siphon/BrowserExtension/NativeMessagingServer.swift \
    Sources/Siphon/BrowserExtension/NativeMessagingHostInstaller.swift \
    Sources/Siphon/BrowserExtension/MCPServer.swift \
    "${KEYCHAIN[@]}"
"$TMP/localauth"

echo "== [24/33] credential scoping (site/origin filter, redirect guard, segment assembler) =="
# The fixtures bind fixed ports (18891/18892). A run that was interrupted leaves
# an echo_server orphaned, and the next run then fails with "fixture servers
# unreachable" for no code reason — reap them first.
pkill -f "fixtures-credscope/echo_server.py" 2>/dev/null || true
swiftc -parse-as-library -o "$TMP/credscope" Tests/CredentialScopeTests/main.swift \
    "${MODELS[@]}" "${SHARED[@]}"
"$TMP/credscope"

echo "== [25/33] Metalink v3/v4 + WebDAV PROPFIND parsers (offline) =="
swiftc -o "$TMP/metalink" Tests/MetalinkTests/main.swift Sources/Siphon/Protocols/MetalinkParser.swift
"$TMP/metalink"
swiftc -o "$TMP/webdav" Tests/WebDAVTests/main.swift Sources/Siphon/Protocols/WebDAVLister.swift
"$TMP/webdav"

echo "== [26/33] self-update feed parsing + version compare + SHA-256 (offline) =="
swiftc -framework AppKit -o "$TMP/updater" Tests/UpdateCheckerTests/main.swift \
    Sources/Siphon/Managers/UpdateChecker.swift
"$TMP/updater"

echo "== [27/33] netrc parsing + host lookup (offline) =="
swiftc -o "$TMP/netrc" Tests/NetRCTests/main.swift Sources/Siphon/Protocols/NetRC.swift
"$TMP/netrc"

echo "== [28/33] streaming preview server (Range + live watermark) =="
swiftc -framework Network -framework Security -o "$TMP/preview" \
    Tests/PreviewServerTests/main.swift \
    Sources/Siphon/Managers/PreviewServer.swift
"$TMP/preview"

echo "== [29/33] native messaging framing (4-byte LE length + caps) =="
swiftc -o "$TMP/nmframing" Tests/NMFramingTests/main.swift \
    Sources/SiphonBridge/NativeMessagingFraming.swift
"$TMP/nmframing"

echo "== [30/33] MDXP JSON-RPC bridge (dispatch + error codes) =="
swiftc -o "$TMP/mdxp" Tests/MDXPBridgeTests/main.swift \
    Sources/Siphon/Managers/MDXPBridge.swift
"$TMP/mdxp"

# Heavy and GUI-dependent: launches the real app, SIGKILLs it mid-download and
# relaunches it. Opt-in so the normal suite stays headless.
if [[ "${SIPHON_GUI_RESTART_E2E:-0}" == "1" ]]; then
    echo "== [opt] GUI restart E2E (A1 auto-resume) =="
    "$ROOT/scripts/verify-restart.sh"
fi

echo "== [31/33] archive safety (Zip Slip, symlinks, entry caps, name sanitizer) =="
python3 - "$TMP" <<'PY'
import sys, os, zipfile
root = sys.argv[1]
with zipfile.ZipFile(os.path.join(root, "traversal.zip"), "w") as z:
    z.writestr("../escaped.txt", "pwned")
    z.writestr("a.txt", "hello")
with zipfile.ZipFile(os.path.join(root, "symlink.zip"), "w") as z:
    info = zipfile.ZipInfo("evil-link")
    info.create_system = 3
    info.external_attr = (0o120777 << 16)
    z.writestr(info, "/etc/passwd")
    z.writestr("a.txt", "hello")
with zipfile.ZipFile(os.path.join(root, "clean.zip"), "w") as z:
    z.writestr("a.txt", "hello")
PY
swiftc -o "$TMP/archivesafety" Tests/ArchiveSafetyTests/main.swift \
    Sources/Siphon/Managers/ArchiveManager.swift \
    Sources/Siphon/Protocols/ContentDisposition.swift
"$TMP/archivesafety" "$TMP/traversal.zip" "$TMP/symlink.zip" "$TMP/clean.zip"

echo "== [32/33] checksum coverage + completion size policy (no silent completion) =="
swiftc -o "$TMP/checksumpolicy" Tests/ChecksumPolicyTests/main.swift \
    Sources/Siphon/Managers/ChecksumPolicy.swift \
    Sources/Siphon/Engines/Shared/CompletionSizePolicy.swift
"$TMP/checksumpolicy"

echo "== [33/33] release assets + source-list consistency =="
plutil -lint Resources/Siphon.entitlements Resources/SiphonHelper.entitlements >/dev/null
bash -n scripts/build-app.sh scripts/notarize.sh scripts/make-dmg.sh scripts/verify.sh
[[ -x scripts/notarize.sh ]] || { echo "notarize.sh is not executable" >&2; exit 1; }
grep -q "SIPHON_SIGN_IDENTITY" scripts/build-app.sh
grep -q "UpdateChecker.verifyStagedBundle" README.md
# Guard the regressions fixed in the last batch: a dead inspector toggle, a
# missing completion-size assertion, and a weak preview token.
grep -q '@AppStorage("Siphon.showInspector")' Sources/Siphon/SiphonApp.swift
! grep -q 'showingInspector: .constant(false)' Sources/Siphon/SiphonApp.swift
grep -q "CompletionSizePolicy" Sources/Siphon/Engines/External/CurlEngine.swift
grep -q "CompletionSizePolicy" Sources/Siphon/Engines/Local/LocalEngine.swift
grep -q "CompletionSizePolicy" Sources/Siphon/Engines/External/SystemTransferEngine.swift
grep -q "SecRandomCopyBytes" Sources/Siphon/Managers/PreviewServer.swift
grep -q "constantTimeEqual" Sources/Siphon/Managers/PreviewServer.swift
[[ -f .github/workflows/verify.yml ]] || { echo "CI workflow missing" >&2; exit 1; }
grep -q "SIPHON_REQUIRE_ARIA2" .github/workflows/verify.yml
# Browser capture: onCreated downloads must not be vetoed by an extension
# allow-list, failed hand-offs must be visible, and the popup must expose its
# own ID so the native-host whitelist can be configured correctly.
grep -q "item.totalBytes" Resources/BrowserExtension/background.js
grep -q "showFailureNotification" Resources/BrowserExtension/background.js
grep -q 'type: "diagnose"' Resources/BrowserExtension/background.js
grep -q "chrome.runtime.id" Resources/BrowserExtension/background.js
grep -q "browser_specific_settings" Resources/BrowserExtension/manifest.json
grep -q "installedManifestSummary" Sources/Siphon/Views/SettingsIntegrationView.swift
! grep -q "自动绑定扩展 ID，无需手动填写" Sources/Siphon/Views/SettingsIntegrationView.swift
# Download popup: every new task must surface the compact NDM-style panel
# (speed / overall / per-segment), it must float without activating the app,
# and a new download must no longer raise the full main window.
grep -q "DownloadPopupController.shared.present" Sources/Siphon/Managers/DownloadStore.swift
grep -q "nonactivatingPanel" Sources/Siphon/Managers/DownloadPopupController.swift
grep -q "segmentSnapshot(for: taskID)" Sources/Siphon/Views/DownloadPopupView.swift
grep -q "DownloadPopupController.PrefKey.onDownload" Sources/Siphon/Views/SettingsGeneralView.swift
! sed -n '/case "add":/,/case "pause":/p' Sources/Siphon/AppDelegate.swift | grep -q "showMainWindow"
# The panel content must stay fully opaque: a transparent底板 lets the desktop
# bleed through and makes the compact window look like floating frosted glass.
grep -q "PopupSurface()" Sources/Siphon/Views/DownloadPopupView.swift
! grep -q "background(.bar" Sources/Siphon/Views/DownloadPopupView.swift
! grep -q "NSVisualEffectView" Sources/Siphon/Views/DownloadPopupView.swift
# Batch operations: selection is a set (⌘/⇧-click), the list exposes a bulk bar,
# the context menu acts on the whole selection, deletes are confirmed once for
# the group, and the 「任务」menu reuses the same store methods.
grep -q "public var selectedTaskIDs" Sources/Siphon/Managers/DownloadStore.swift
grep -q "func deleteTasks" Sources/Siphon/Managers/DownloadStore.swift
grep -q "func pauseTasks" Sources/Siphon/Managers/DownloadStore.swift
grep -q "List(selection: selectionBinding)" Sources/Siphon/Views/TaskListView.swift
grep -q "private var batchBar" Sources/Siphon/Views/TaskListView.swift
grep -q "private var batchContextMenu" Sources/Siphon/Views/TaskListView.swift
grep -q "BatchSelectionPanel" Sources/Siphon/Views/ContentView.swift
grep -q "暂停所选" Sources/Siphon/SiphonApp.swift
! grep -q "deleteCandidate" Sources/Siphon/Views/TaskListView.swift
# Probe fail-fast: a TCP-level failure (dead manual proxy, refused connection)
# must surface as a task error instead of looping forever at "active 0 B".
grep -q "gotHTTPResponse" Sources/Siphon/Engines/NativeHTTP/HTTPDownloadEngine.swift
grep -q "代理不可用" Sources/Siphon/Engines/NativeHTTP/HTTPDownloadEngine.swift
# Single-instance lock must use flock: NSDistributedLock represents the lock as a
# directory, so a SIGKILLed instance left behind a "bad lock" that bricked every
# later launch — and deleting that directory would release a *live* peer's lock.
grep -q "flock(fd, LOCK_EX | LOCK_NB)" Sources/Siphon/AppDelegate.swift
! grep -q "NSDistributedLock" Sources/Siphon/AppDelegate.swift
# Self-generated secrets (REST token, aria2 RPC secret) must live in 0600
# files, not the keychain: every reinstall of an ad-hoc-signed build changes
# its CDHash, and the keychain ACL check would raise a modal prompt at launch.
# Reading migrated keychain items is forbidden — only the data-free existence
# probe (Keychain.hasSecret) may be used before deletion.
grep -q "LocalAuthBootstrap.read()" Sources/Siphon/Managers/LocalAuthToken.swift
grep -q 'LocalAuthBootstrap.read(fileName: fileName)' Sources/Siphon/Engines/Aria2/Aria2Bootstrap.swift
! grep -q "Keychain.secret" Sources/Siphon/Managers/LocalAuthToken.swift
! grep -q "Keychain.secret" Sources/Siphon/Engines/Aria2/Aria2Bootstrap.swift
# A stale `captureAll: false` in extension storage silently disables capture;
# keep the one-time upgrade repair and the version bump that triggers it.
grep -q "CAPTURE_MIGRATION_KEY" Resources/BrowserExtension/background.js
grep -q '"version": "0.4.1"' Resources/BrowserExtension/manifest.json
grep -q '"version": "0.4.1"' Resources/BrowserExtension/manifest-firefox.json
python3 -c 'import json; json.load(open("Resources/BrowserExtension/manifest.json"))'
python3 -c 'import json; json.load(open("Resources/BrowserExtension/manifest-firefox.json"))'
if command -v node >/dev/null 2>&1; then
    node --check Resources/BrowserExtension/background.js
    node --check Resources/BrowserExtension/popup.js
fi
# The suite hand-lists swiftc inputs. Report coverage and fail on stale paths:
# a newly added source that is referenced must be added to the right list, or a
# step breaks; a path that was deleted must be removed from the list.
python3 - <<'PY'
import os, re, sys
script = open("scripts/verify.sh", encoding="utf-8").read()
referenced = set(re.findall(r"Sources/[\w/\-]+\.swift", script))
sources = [os.path.join(root, name)
           for root, _, files in os.walk("Sources")
           for name in files if name.endswith(".swift")]
stale = sorted(p for p in referenced if not os.path.isfile(p))
if stale:
    print("FAIL  verify.sh references missing sources:", stale)
    sys.exit(1)
uncovered = sorted(p for p in sources if p not in referenced)
print(f"INFO  {len(sources) - len(uncovered)}/{len(sources)} Swift sources compiled by the suite")
print(f"INFO  {len(uncovered)} sources covered by `swift build` only (no swiftc unit step)")
PY
echo "PASS  release assets + source lists"

echo
echo "ALL CHECKS PASSED"