#!/usr/bin/env bash
# A1 GUI restart end-to-end verification.
#
# Runs the real SwiftUI app binary (an isolated copy, so the user's preferences,
# download folder and tasks.json are untouched):
#   1. launch → POST /add via the loopback REST API → task starts downloading;
#   2. SIGKILL mid-download (simulating a crash, not a graceful quit);
#   3. assert tasks.json recorded state=active + wasActive=true;
#   4. relaunch → the task resumes with NO manual action and continues from the
#      persisted segment cursors (first range request starts at an intermediate
#      offset, not 0);
#   5. assert the output file completes byte-for-byte;
#   6. a second crash with -Siphon.autoResumeInterrupted NO must leave the task
#      paused (the preference gates the auto-resume).
#
# Requirements: macOS GUI session, port 17801 free, `.build/debug/Siphon` built
# (run `swift build` first).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_SRC="$ROOT/.build/debug/Siphon"
PORT="${SIPHON_E2E_PORT:-18791}"
API="http://127.0.0.1:17801"
TOKEN="siphon-e2e-$$"
TOTAL=$((24 * 1024 * 1024))
KILL_BYTES=$((4 * 1024 * 1024))
URL_A="http://127.0.0.1:$PORT/slow.bin"
URL_B="http://127.0.0.1:$PORT/slow2.bin"

FAILS=0
TMP="$(mktemp -d /tmp/siphon-restart.XXXXXX)"
HOME_DIR="$TMP/home"
BIN="$TMP/SiphonE2E"
mkdir -p "$HOME_DIR/Downloads" "$HOME_DIR/Library/Application Support/Siphon"
APP_PID=""
SERVER_PID=""

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
check() { if [[ "$2" == "0" ]]; then pass "$1"; else fail "$1${3:+ ($3)}"; fi; }
die() {
    echo "FAIL  $*"
    [[ -f "$TMP/app.log" ]] && { echo "--- app.log (tail) ---"; tail -20 "$TMP/app.log"; }
    exit 1
}

kill_app() {
    if [[ -n "$APP_PID" ]]; then
        kill -9 "$APP_PID" 2>/dev/null
        wait "$APP_PID" 2>/dev/null
        APP_PID=""
    fi
    pkill -f "$BIN" 2>/dev/null
    sleep 0.2
}

cleanup() {
    kill_app
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    # The renamed binary uses its own UserDefaults domain; drop everything it wrote.
    defaults delete SiphonE2E >/dev/null 2>&1
    rm -f "$HOME/Library/Preferences/SiphonE2E.plist"
    rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------- fixtures
write_fixtures() {
    cat > "$TMP/server.py" <<'PY'
import hashlib, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, LOG, HASH = int(sys.argv[1]), sys.argv[2], sys.argv[3]
TOTAL = 24 * 1024 * 1024
PAYLOAD = bytes(((i * 7 + 13) % 251) for i in range(TOTAL))
CHUNK, DELAY = 4096, 0.02          # ~200 KB/s per connection
open(HASH, "w").write(hashlib.sha256(PAYLOAD).hexdigest() + "\n")

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def note(self, start):
        with open(LOG, "a") as f:
            f.write("GET %d\n" % start)
    def limits(self):
        r = self.headers.get("Range")
        if not r or "bytes=" not in r: return None
        spec = r.split("=", 1)[1].split(",")[0]
        a, b = spec.split("-")
        return (int(a) if a else 0), min(int(b) if b else TOTAL - 1, TOTAL - 1)
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Length", str(TOTAL))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
    def do_GET(self):
        rng = self.limits()
        start, end = rng if rng else (0, TOTAL - 1)
        self.note(start)
        self.send_response(206 if rng else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if rng:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, TOTAL))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        pos = start
        try:
            while pos <= end:
                n = min(CHUNK, end - pos + 1)
                self.wfile.write(PAYLOAD[pos:pos + n])
                pos += n
                time.sleep(DELAY)
        except (BrokenPipeError, ConnectionResetError):
            pass

ThreadingHTTPServer.daemon_threads = True
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY

    cat > "$TMP/api.py" <<'PY'
import json, sys, time, urllib.request
api, token, url, mode = sys.argv[1:5]
timeout, min_bytes = float(sys.argv[5]), int(sys.argv[6])

def fetch():
    req = urllib.request.Request(api + "/tasks",
                                 headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=2) as r:
        return json.load(r).get("tasks", [])

def pick(ts):
    return next((t for t in ts if t.get("url") == url), None)

last = None
deadline = time.time() + timeout
while True:
    try:
        t = pick(fetch())
    except Exception:
        t = None
    last = t or last
    if t:
        state = t.get("state")
        if mode == "progress" and state in ("pending", "active") \
                and t.get("downloaded", 0) >= min_bytes: break
        if mode == "resumed" and state in ("pending", "active", "completed"): break
        if mode == "completed" and state == "completed" \
                and t.get("downloaded", 0) >= min_bytes: break
        if mode == "paused" and state == "paused": break
        if mode == "snapshot": break
    if time.time() >= deadline:
        print(json.dumps(last))
        sys.exit(2)
    time.sleep(0.15)
print(json.dumps(last))
PY

    cat > "$TMP/check_json.py" <<'PY'
import json, sys
path, url, want_state, want_was = sys.argv[1:5]
try:
    recs = json.load(open(path))
except Exception as e:
    print("cannot read tasks.json: %s" % e, file=sys.stderr)
    sys.exit(2)
rec = next((r for r in recs if r.get("source") == url), None)
if not rec:
    print("task not found in tasks.json", file=sys.stderr)
    sys.exit(3)
ok = rec.get("state") == want_state
if want_was == "true":
    ok = ok and rec.get("wasActive") is True
elif want_was == "false":
    ok = ok and rec.get("wasActive") is not True
print(json.dumps({"state": rec.get("state"), "wasActive": rec.get("wasActive"),
                  "destination": rec.get("destination"), "name": rec.get("name")}))
sys.exit(0 if ok else 1)
PY

    cat > "$TMP/ranges.py" <<'PY'
import sys, time
path, timeout = sys.argv[1], float(sys.argv[2])
deadline = time.time() + timeout
while time.time() < deadline:
    lines = [l.strip() for l in open(path) if l.strip()]
    idx = max((i for i, l in enumerate(lines) if l.startswith("MARK")), default=-1)
    reqs = [int(l.split()[1]) for l in lines[idx + 1:] if l.startswith("GET ")]
    if reqs:
        print(reqs[0])
        sys.exit(0)
    time.sleep(0.1)
print(-1)
sys.exit(2)
PY
}

# ---------------------------------------------------------------- helpers
launch() {
    kill_app
    # A stale listener would make every later /tasks request hit the wrong
    # process, so wait for the previous instance's port to be released.
    for _ in $(seq 1 20); do
        lsof -nP -iTCP:17801 -sTCP:LISTEN >/dev/null 2>&1 || break
        sleep 0.2
    done
    lsof -nP -iTCP:17801 -sTCP:LISTEN >/dev/null 2>&1 \
        && die "port 17801 still held before launch"
    CFFIXED_USER_HOME="$HOME_DIR" SIPHON_LOCAL_API_TOKEN="$TOKEN" \
        "$BIN" -Siphon.browserCaptureEnabled YES "$@" >>"$TMP/app.log" 2>&1 &
    APP_PID=$!
    sleep 0.3
    kill -0 "$APP_PID" 2>/dev/null || die "app exited right after launch"
}

wait_api() {
    for _ in $(seq 1 120); do
        curl -fsS --max-time 1 "$API/ping" >/dev/null 2>&1 && break
        sleep 0.25
    done
    # The listener must belong to the instance we just launched (guards against
    # a leftover process serving the API).
    local owner
    owner="$(lsof -nP -iTCP:17801 -sTCP:LISTEN -t 2>/dev/null | head -1)"
    [[ -n "$owner" && "$owner" == "$APP_PID" ]]
}

add_task() {
    curl -fsS -X POST "$API/add" -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" -d "{\"url\":\"$1\"}" >/dev/null
}

json_field() {
    python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

# ---------------------------------------------------------------- preconditions
[[ -x "$BIN_SRC" ]] || die "missing $BIN_SRC — run: swift build"
lsof -nP -iTCP:17801 -sTCP:LISTEN >/dev/null 2>&1 \
    && die "port 17801 is already in use (is another Siphon instance running?)"
cp "$BIN_SRC" "$BIN" && chmod +x "$BIN"
write_fixtures
TASKS_JSON="$HOME_DIR/Library/Application Support/Siphon/tasks.json"
echo "== A1 GUI restart E2E (tmp: $TMP) =="

python3 "$TMP/server.py" "$PORT" "$TMP/ranges.log" "$TMP/payload.sha" \
    >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null
for _ in $(seq 1 60); do
    curl -fsS --max-time 1 -I "http://127.0.0.1:$PORT/slow.bin" >/dev/null 2>&1 && break
    sleep 0.25
done
[[ -s "$TMP/payload.sha" ]] || die "fixture server failed to start"

# ---------------------------------------------------------------- phase 1: crash mid-download
launch -Siphon.autoResumeInterrupted YES
wait_api || die "control server never came up"
add_task "$URL_A" || die "POST /add failed"

SNAP="$(python3 "$TMP/api.py" "$API" "$TOKEN" "$URL_A" progress 45 "$KILL_BYTES")" \
    || die "task never reached $KILL_BYTES bytes: $SNAP"
D1="$(json_field "$SNAP" downloaded)"
echo "downloaded before crash: $D1 bytes"

kill_app
REC="$(python3 "$TMP/check_json.py" "$TASKS_JSON" "$URL_A" active true)" \
    || die "tasks.json not active+wasActive after crash: $REC"
DEST="$(json_field "$REC" destination)"
DEST_PATH="$(python3 -c 'import sys, urllib.parse; u = urllib.parse.urlparse(sys.argv[1]); print(urllib.parse.unquote(u.path) if u.scheme == "file" else sys.argv[1])' "$DEST")"
echo "persisted marker: $REC"
check "tasks.json kept state=active and wasActive=true" 0

# ---------------------------------------------------------------- phase 2: auto-resume
printf 'MARK\n' >> "$TMP/ranges.log"
launch -Siphon.autoResumeInterrupted YES
wait_api || die "control server did not come back after relaunch"

python3 "$TMP/api.py" "$API" "$TOKEN" "$URL_A" resumed 45 1 >/dev/null \
    || die "task was not auto-resumed after relaunch (stayed paused)"
check "task auto-resumed after relaunch without user action" 0

FIRST_RANGE="$(python3 "$TMP/ranges.py" "$TMP/ranges.log" 10)"
if [[ "$FIRST_RANGE" -gt 0 ]]; then
    check "resumed from persisted cursors (first Range start=$FIRST_RANGE)" 0
else
    fail "download restarted from 0 instead of resuming (first Range start=$FIRST_RANGE)"
fi

FINAL="$(python3 "$TMP/api.py" "$API" "$TOKEN" "$URL_A" completed 150 "$TOTAL")" \
    || die "task did not complete after resume: $FINAL"
TOTAL_GOT="$(json_field "$FINAL" total)"
DONE_GOT="$(json_field "$FINAL" downloaded)"
check "completed with downloaded=$DONE_GOT total=$TOTAL_GOT" \
    "$([[ "$DONE_GOT" == "$TOTAL" && "$TOTAL_GOT" == "$TOTAL" ]] && echo 0 || echo 1)"

for _ in $(seq 1 40); do [[ -f "$DEST_PATH" ]] && break; sleep 0.25; done
GOT_HASH="$(shasum -a 256 "$DEST_PATH" 2>/dev/null | awk '{print $1}')"
WANT_HASH="$(cat "$TMP/payload.sha")"
check "output file matches fixture byte-for-byte" \
    "$([[ "$GOT_HASH" == "$WANT_HASH" ]] && echo 0 || echo 1)" "$GOT_HASH"
check ".part file removed after publish" \
    "$([[ ! -f "$DEST_PATH.part" ]] && echo 0 || echo 1)"
kill_app

# ---------------------------------------------------------------- phase 3: preference off must not resume
launch -Siphon.autoResumeInterrupted YES
wait_api || die "control server did not start for phase 3"
add_task "$URL_B" || die "POST /add (second task) failed"
python3 "$TMP/api.py" "$API" "$TOKEN" "$URL_B" progress 45 $((KILL_BYTES / 2)) >/dev/null \
    || die "second task never reached the kill threshold"
kill_app

python3 "$TMP/check_json.py" "$TASKS_JSON" "$URL_B" active true >/dev/null \
    || die "second task was not recorded as interrupted"

launch -Siphon.autoResumeInterrupted NO
wait_api || die "control server did not start with auto-resume disabled"
sleep 4
SNAP="$(python3 "$TMP/api.py" "$API" "$TOKEN" "$URL_B" snapshot 1 0)"
STATE="$(json_field "$SNAP" state)"
check "auto-resume off keeps the interrupted task paused (state=$STATE)" \
    "$([[ "$STATE" == "paused" ]] && echo 0 || echo 1)" "$STATE"
kill_app

echo
if [[ $FAILS -eq 0 ]]; then
    echo "GUI RESTART E2E: ALL PASS"
    exit 0
fi
echo "GUI RESTART E2E: $FAILS FAILURE(S)"
exit 1
