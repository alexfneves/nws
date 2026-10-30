#!/usr/bin/env bash
# tests/smoke_unix_socket.sh — end-to-end smoke test of the Unix control socket.
#
# Runs real `nws service` daemons against an ISOLATED home and runtime dir, so
# the user's config (~/.config/nws) and live socket are never touched:
#
#   mkdir -m 0700 -p /tmp/nws-dev-home /tmp/nws-dev-run
#   HOME=/tmp/nws-dev-home XDG_RUNTIME_DIR=/tmp/nws-dev-run \
#     NWS=./result/bin/nws bash tests/smoke_unix_socket.sh
#
# Refuses to run unless HOME and XDG_RUNTIME_DIR both live under /tmp/nws-*.
# It only ever signals the daemons it started itself (by recorded PID), and
# deletes only $HOME/.config/nws, $XDG_RUNTIME_DIR/nws* and its own mktemp dirs.
set -euo pipefail

case "${HOME:-}" in /tmp/nws-*) ;; *)
  echo "refusing to run: HOME must be under /tmp/nws-* (got '${HOME:-}')" >&2; exit 2 ;;
esac
case "${XDG_RUNTIME_DIR:-}" in /tmp/nws-*) ;; *)
  echo "refusing to run: XDG_RUNTIME_DIR must be under /tmp/nws-* (got '${XDG_RUNTIME_DIR:-}')" >&2; exit 2 ;;
esac
unset NWS_SOCKET

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NWS="${NWS:-}"
[ -n "$NWS" ] || { [ -x "$ROOT/result/bin/nws" ] && NWS="$ROOT/result/bin/nws"; } || true
[ -n "$NWS" ] || NWS="$(command -v nws || true)"
[ -x "$NWS" ] || { echo "no nws binary (set NWS=...)" >&2; exit 2; }

SOCK_DIR="$XDG_RUNTIME_DIR/nws"
SOCK="$SOCK_DIR/control.sock"
CFG="$HOME/.config/nws/config.json"
WORK="$(mktemp -d /tmp/nws-smoke.XXXXXX)"
PIDS=()

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$*"; }
skip() { printf 'skip - %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

cleanup() {
  local p
  for p in "${PIDS[@]}"; do
    kill -0 "$p" 2>/dev/null && { kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; }
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# start_daemon LOG: start `nws service` in the background, set DPID, and wait
# until it answers `nws list` (or exits).
start_daemon() {
  local log="$1" i
  "$NWS" service >"$log" 2>&1 &
  DPID=$!
  PIDS+=("$DPID")
  for i in $(seq 1 50); do
    "$NWS" list >/dev/null 2>&1 && return 0
    kill -0 "$DPID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

stop_daemon() { # stop_daemon PID [SIGNAL]
  kill -"${2:-TERM}" "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

mode_of() { stat -c '%a' "$1"; }

echo "== setup: nws=$NWS sock=$SOCK"
rm -rf "$HOME/.config/nws" "$SOCK_DIR" "$XDG_RUNTIME_DIR"/nws-alt
mkdir -p "$SOCK_DIR" && chmod 0755 "$SOCK_DIR"   # loose on purpose: must be fixed

echo "== daemon 1 starts; directory and socket permissions"
if start_daemon "$WORK/d1.log"; then ok "daemon 1 up (pid $DPID)"; else bad "daemon 1 did not come up"; cat "$WORK/d1.log"; exit 1; fi
D1=$DPID
check "socket dir is 0700 (was 0755)" [ "$(mode_of "$SOCK_DIR")" = 700 ]
check "socket is a socket" [ -S "$SOCK" ]
check "socket is 0600" [ "$(mode_of "$SOCK")" = 600 ]
check "log says 'listening on $SOCK'" grep -qF "listening on $SOCK" "$WORK/d1.log"
if command -v ss >/dev/null 2>&1; then
  check "daemon holds no TCP listener" bash -c "! ss -ltnp 2>/dev/null | grep -q 'pid=$D1,'"
else skip "ss not installed: TCP listener check"; fi

echo "== register / list / unregister"
WS="$WORK/ws"; mkdir -p "$WS/child"
out="$("$NWS" register "$WS" 2>&1)"; check "register prints OK ($out)" [ "$out" = OK ]
check "list shows the workspace" bash -c "'$NWS' list | grep -qxF '$WS'"
for i in $(seq 1 30); do [ -f "$WS/flake.nix" ] && break; sleep 0.1; done
check "daemon generated the root flake.nix" [ -f "$WS/flake.nix" ]
out="$("$NWS" register "$WS" 2>&1)"; check "second register is refused ($out)" [ "$out" = "ERROR already registered" ]
OWS="$WORK/ows"; mkdir -p "$OWS/pkg"
out="$("$NWS" register "$OWS" --overlay github:example/overlay --attr-path pkgs 2>&1)"
check "overlay register prints OK ($out)" [ "$out" = OK ]
if command -v python3 >/dev/null 2>&1; then
  check "daemon-written config.json is strict JSON (python json)" python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CFG"
else skip "python3 not installed: strict JSON check of config.json"; fi
check "config.json has no \"port\" key" bash -c "! grep -q '\"port\"' '$CFG'"
out="$("$NWS" unregister "$OWS" 2>&1)"; check "overlay unregister prints OK" [ "$out" = OK ]
out="$("$NWS" unregister "$WS" 2>&1)"; check "unregister prints OK" [ "$out" = OK ]
check "list no longer shows the workspace" bash -c "! '$NWS' list | grep -qxF '$WS'"

echo "== a second daemon refuses to start while the first runs"
INO_BEFORE="$(stat -c %i "$SOCK")"
rc=0; timeout 10 "$NWS" service >"$WORK/d2.log" 2>&1 || rc=$?
check "second daemon exits non-zero (rc=$rc)" test "$rc" -ne 0 -a "$rc" -ne 124
check "second daemon says 'another daemon is listening on $SOCK'" grep -qF "nws: another daemon is listening on $SOCK" "$WORK/d2.log"
check "first daemon still alive" kill -0 "$D1"
check "socket file untouched (same inode)" [ "$(stat -c %i "$SOCK")" = "$INO_BEFORE" ]
check "first daemon still answers" bash -c "'$NWS' list >/dev/null"

echo "== clients that hang up before the reply cannot SIGPIPE the daemon"
if command -v python3 >/dev/null 2>&1; then
  rc=0
  python3 - "$SOCK" <<'PY' || rc=$?
import socket, sys
for _ in range(50):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sys.argv[1])
    s.sendall(b"LIST\n")
    s.close()          # gone before the daemon writes its reply -> EPIPE
PY
  sleep 0.3
  check "50 early hang-up clients all connected (rc=$rc)" [ "$rc" -eq 0 ]
  check "daemon survived 50 early hang-ups" kill -0 "$D1"
  check "daemon still answers after early hang-ups" bash -c "'$NWS' list >/dev/null"
else skip "python3 not installed: early hang-up check"; fi

echo "== raw wire protocol via nc -U"
if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-U'; then
  reply="$(printf 'LIST\n' | timeout 5 nc -U "$SOCK" || true)"
  check "nc -U LIST replies 'OK 0' (got '${reply%%$'\n'*}')" [ "${reply%%$'\n'*}" = "OK 0" ]
else skip "nc without -U support: raw LIST check"; fi

echo "== TERM removes the socket; a new daemon starts"
stop_daemon "$D1" TERM
if [ ! -e "$SOCK" ]; then ok "socket removed on TERM"
elif [ -S "$SOCK" ]; then ok "socket left stale after TERM (accepted)"
else bad "socket path is no longer a socket"; fi
check "log says 'stopping'" grep -qF "stopping" "$WORK/d1.log"
rc=0; out="$("$NWS" list 2>&1)" || rc=$?
check "client with no daemon exits non-zero (rc=$rc)" [ "$rc" -ne 0 ]
check "client names the socket ('$out')" [ "$out" = "nws: no daemon listening on $SOCK (start one with: nws service)" ]
if start_daemon "$WORK/d3.log"; then ok "daemon 3 up after TERM (pid $DPID)"; else bad "daemon 3 did not come up"; cat "$WORK/d3.log"; fi
D3=$DPID

echo "== a stale socket (daemon killed with KILL) is replaced"
stop_daemon "$D3" KILL
check "socket left behind by KILL" [ -S "$SOCK" ]
if start_daemon "$WORK/d4.log"; then ok "daemon 4 up over a stale socket (pid $DPID)"; else bad "daemon 4 did not come up"; cat "$WORK/d4.log"; fi
D4=$DPID
check "log says it removed the stale socket" grep -qF "removing stale socket $SOCK" "$WORK/d4.log"
stop_daemon "$D4" TERM

echo "== a non-socket file at the path is never deleted"
rm -f "$SOCK"; echo keep >"$SOCK"
rc=0; timeout 10 "$NWS" service >"$WORK/d5.log" 2>&1 || rc=$?
check "daemon refuses (rc=$rc)" test "$rc" -ne 0 -a "$rc" -ne 124
check "error says not a socket" grep -qF "exists and is not a socket" "$WORK/d5.log"
check "regular file still there" [ "$(cat "$SOCK")" = keep ]
rm -f "$SOCK"

echo "== socket parent directory policy"
if [ "$(stat -c %u /tmp)" != "$(id -u)" ]; then
  rc=0; NWS_SOCKET=/tmp/nws-smoke-foreign.sock timeout 10 "$NWS" service >"$WORK/d6.log" 2>&1 || rc=$?
  check "parent dir owned by another uid is refused (rc=$rc)" test "$rc" -ne 0 -a "$rc" -ne 124
  check "error names the owner" grep -qF "socket directory /tmp is owned by uid" "$WORK/d6.log"
  check "no socket created in /tmp" [ ! -e /tmp/nws-smoke-foreign.sock ]
else skip "/tmp is owned by us: foreign-owner check"; fi
rc=0; NWS_SOCKET="$XDG_RUNTIME_DIR/$(printf 'x%.0s' $(seq 1 120)).sock" "$NWS" list >"$WORK/long.log" 2>&1 || rc=$?
check "over-long socket path refused (rc=$rc)" [ "$rc" -ne 0 ]
check "error names the 108-byte limit" grep -qF "108 bytes including the NUL" "$WORK/long.log"

echo "== NWS_SOCKET override"
ALT="$XDG_RUNTIME_DIR/nws-alt/ctl.sock"
export NWS_SOCKET="$ALT"
if start_daemon "$WORK/d7.log"; then ok "daemon on NWS_SOCKET up"; else bad "daemon on NWS_SOCKET did not come up"; cat "$WORK/d7.log"; fi
check "socket at NWS_SOCKET" [ -S "$ALT" ]
check "NWS_SOCKET dir is 0700" [ "$(mode_of "$(dirname "$ALT")")" = 700 ]
stop_daemon "$DPID" TERM
unset NWS_SOCKET
rm -rf "$XDG_RUNTIME_DIR/nws-alt"

echo "== legacy \"port\" config key"
mkdir -p "$(dirname "$CFG")"
printf '{\n  "port": 17424,\n  "workspaces": []\n}\n' >"$CFG"
WARN='nws: config key "port" is no longer used; the control channel is a Unix socket'
"$NWS" list >"$WORK/port-client.log" 2>&1 || true
check "client prints the port warning" grep -qxF "$WARN" "$WORK/port-client.log"
check "client prints it once" [ "$(grep -cxF "$WARN" "$WORK/port-client.log")" = 1 ]
if start_daemon "$WORK/d8.log"; then ok "daemon starts with a legacy port key"; else bad "daemon refused a legacy port key"; cat "$WORK/d8.log"; fi
check "daemon prints the port warning" grep -qxF "$WARN" "$WORK/d8.log"
stop_daemon "$DPID" TERM

printf -- '----\nsmoke tests: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
