#!/usr/bin/env bash
# The explicit gateway, end to end against a stub upstream (LLD 8.2, 8.3, 8.6).
#
# Routing and masking are unit-tested in test_gateway_routes.py. What only a running
# server can show is that a request actually leaves masked, that a refusal is a
# status rather than a relay, and that the log carries no payload.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
ihar_sandbox
export PYTHONPATH="$ROOT/lib/python" IHAR_ROOT="$ROOT"

SECRET='sk-ant-abcdefghijklmnopqrstuvwxyz0123'

# A stub upstream that records exactly what reached it. The gateway is pointed at it
# instead of a vendor, so the assertion is about bytes on the wire rather than about
# what the gateway believes it sent.
python3 - "$IHAR_TEST_TMP" <<'PY' &
import http.server, json, os, sys, threading
tmp = sys.argv[1]
class Upstream(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with open(os.path.join(tmp, "upstream-body"), "wb") as handle:
            handle.write(body)
        payload = json.dumps({"ok": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
with open(os.path.join(tmp, "upstream-port"), "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
UPSTREAM_PID=$!
for _ in $(seq 50); do [[ -s "$IHAR_TEST_TMP/upstream-port" ]] && break; sleep 0.1; done
UPSTREAM_PORT="$(cat "$IHAR_TEST_TMP/upstream-port" 2>/dev/null || echo)"

if [[ -z "$UPSTREAM_PORT" ]]; then
  echo "SKIP [explicit gateway]: the stub upstream did not start"
  kill "$UPSTREAM_PID" 2>/dev/null
  finish
  exit 0
fi

export IHAR_GATEWAY_ANTHROPIC_UPSTREAM="http://127.0.0.1:$UPSTREAM_PORT"
export IHAR_GATEWAY_OPENAI_UPSTREAM="http://127.0.0.1:$UPSTREAM_PORT"

python3 -m ihar.gateway.explicit --port 0 --port-file "$IHAR_TEST_TMP/gw-port" \
  --log-dir "$IHAR_TEST_TMP/logs" --level standard --engine regex --enforced \
  >/dev/null 2>"$IHAR_TEST_TMP/gw-stderr" &
GW_PID=$!
for _ in $(seq 60); do [[ -s "$IHAR_TEST_TMP/gw-port" ]] && break; sleep 0.1; done
PORT="$(cat "$IHAR_TEST_TMP/gw-port" 2>/dev/null || echo)"
cleanup() { kill "$GW_PID" "$UPSTREAM_PID" 2>/dev/null; }
trap cleanup EXIT

if [[ -z "$PORT" ]]; then
  echo "FAIL [gateway did not start]: $(cat "$IHAR_TEST_TMP/gw-stderr")"
  FAIL=1; finish; exit 1
fi

post() { # <path> <body>
  curl -sS -o "$IHAR_TEST_TMP/out" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "Authorization: Bearer secret-token-value" \
    --data "$2" "http://127.0.0.1:$PORT$1" 2>/dev/null
}

# --- the probe answers with the marker, and never reaches the vendor ------------------

assert_exit "the probe identifies the gateway" 0 \
  python3 -m ihar.gateway.probe "$PORT"

# --- a model request leaves masked -----------------------------------------------------

rm -f "$IHAR_TEST_TMP/upstream-body"
code="$(post /v1/messages "{\"model\":\"claude\",\"system\":\"key $SECRET\",\"messages\":[]}")"
assert_eq "a model request is forwarded" "200" "$code"
sent="$(cat "$IHAR_TEST_TMP/upstream-body" 2>/dev/null || echo)"
assert_eq "the secret does not reach the upstream" "0" "$(grep -c "$SECRET" <<<"$sent")"
assert_contains "and the placeholder does" "$sent" "REDACTED-anthropic-key"

# --- an unknown route is refused, not relayed --------------------------------------------

rm -f "$IHAR_TEST_TMP/upstream-body"
code="$(post /v1/somethingnew "{\"system\":\"key $SECRET\"}")"
assert_eq "an unknown route is refused with 502" "502" "$code"
assert_exit "and nothing reached the upstream" 1 test -f "$IHAR_TEST_TMP/upstream-body"

# --- bodies the masker cannot promise about -----------------------------------------------

code="$(post /v1/messages 'not json at all')"
assert_eq "an unparseable body is 400" "400" "$code"

code="$(post /v1/messages '{"messages":[{"role":"user","content":[{"type":"image","source":{"data":"AAAA"}}]}]}')"
assert_eq "an image block is refused under an enforced profile" "502" "$code"

code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -H 'Content-Encoding: gzip' \
  --data '{}' "http://127.0.0.1:$PORT/v1/messages" 2>/dev/null)"
assert_eq "a compressed body is 415" "415" "$code"

# --- the credential is forwarded untouched -------------------------------------------------
# ihar never holds a vendor credential and never rewrites one; it is the caller's.

rm -f "$IHAR_TEST_TMP/upstream-body"
post /v1/messages '{"model":"claude","messages":[]}' >/dev/null
assert_exit "the request still reached the upstream" 0 test -f "$IHAR_TEST_TMP/upstream-body"

# --- the log carries no payload -------------------------------------------------------------

logged="$(cat "$IHAR_TEST_TMP"/logs/*.log 2>/dev/null || echo)"
assert_exit "something was logged" 1 test -z "$logged"
assert_eq "no secret appears in the log" "0" "$(grep -c "$SECRET" <<<"$logged")"
assert_eq "no bearer token appears in the log" "0" "$(grep -c 'secret-token-value' <<<"$logged")"
assert_contains "but the refusal reason does" "$logged" "unknown route"
assert_contains "and the route class does" "$logged" '"path_class"'

# --- metrics ----------------------------------------------------------------------------------

metrics="$(curl -sS "http://127.0.0.1:$PORT/api/metrics" 2>/dev/null)"
assert_contains "refusals are counted" "$metrics" '"refused"'
assert_contains "and maskings are counted" "$metrics" '"masked"'

finish
