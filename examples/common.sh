#!/usr/bin/env bash
# examples/common.sh — shared new-style plumbing for the nws example run scripts.
#
# New-style example contract (plan D1):
#   * nws is INSTALLED, not repo-local: the binary comes from the $NWS env
#     override, else `command -v nws`. Missing -> hard error with an install
#     hint. There is NO walking up folder trees for a built nws anywhere.
#   * The workspace is the CURRENT folder ($PWD): clones land here, the
#     resolver is copied here, and this folder is registered. The script
#     refuses to run from the nws repo root (AGENTS.md + examples/ present)
#     so the repo's own flake.nix can never be clobbered by an accident.
#   * Daemon policy: probe liveness on the WIRE — a live daemon answers a
#     raw `LIST` request with `OK <count>...` (list_reply). The probe reads
#     that reply directly: every nws client command exits 0 even against a
#     dead daemon (it prints an error and returns), AND `nws list`'s client
#     strips the OK header and prints only the workspace paths — so neither
#     the exit code nor the client's stdout can signal reachability. If a
#     daemon is reachable it is USED — never killed, never restarted.
#     Otherwise one is spawned (`nws service > /tmp/nws-example-<name>-
#     daemon.log 2>&1 &`) and an EXIT/INT/TERM trap kills ONLY that PID
#     (kill -0-guarded, then wait) — never process-kills anything it did not
#     start. Passing --hold (or HOLD=1) keeps the spawned daemon alive and
#     holds instead of exiting (then no kill-trap is registered at all).
#   * Registration is idempotent: `nws list | grep -qxF "$PWD"` skips a
#     previous registration; a reply containing `ERROR already registered`
#     (a race) counts as success. NEVER de-register, never delete folders.
#
# Sourced by each example's run.sh; set EXAMPLE_NAME first (used for the
# daemon log name). The install check, repo-root guard, banner and daemon
# setup all run at source time. Bash-only (bashisms: local, $'\n', arrays).

set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: run the example with bash:  bash $0" >&2
  exit 1
fi

EXAMPLE_NAME="${EXAMPLE_NAME:-example}"
WS="$PWD"                                   # workspace = the current folder

# --- --hold / HOLD=1: keep our own spawned daemon and hold; default: exit ---
NWS_HOLD=0
[ "${HOLD:-0}" = "1" ] && NWS_HOLD=1
for _arg in "$@"; do
  [ "$_arg" = "--hold" ] && NWS_HOLD=1
done
unset _arg

# --- binary: $NWS env override, else command -v nws; never a result/ walk ---
if [ -n "${NWS:-}" ]; then
  NWS_BIN="$NWS"
else
  NWS_BIN="$(command -v nws || true)"
fi
if [ -z "${NWS_BIN:-}" ] || [ ! -x "$NWS_BIN" ]; then
  echo "ERROR: the nws binary is not installed." >&2
  echo "This example needs nws INSTALLED (no more repo-local binary lookup)." >&2
  echo "Install it, then re-run this script:" >&2
  echo "    nix profile install .#main" >&2
  echo "  or put the built nws on your PATH:" >&2
  echo "    nix build .#main && export PATH=\"\$PWD/result/bin:\$PATH\"" >&2
  exit 1
fi

# --- repo-root guard: $PWD looks like the nws repo -> refuse (exit only) ---
if [ -f "$PWD/AGENTS.md" ] && [ -d "$PWD/examples" ]; then
  echo "FATAL: this looks like the nws repository root — refusing to run." >&2
  echo "run.sh sets up the CURRENT folder as an nws workspace and would" >&2
  echo "clobber the repo's own flake.nix. Run from your own empty folder:" >&2
  echo "    mkdir demo && cd demo && bash <nws-repo>/examples/$EXAMPLE_NAME/run.sh" >&2
  exit 1
fi

echo "==> nws binary: $NWS_BIN"
echo "==> workspace:  $WS"

# --- daemon: use the user's if reachable; spawn + own-kill only our own ------
NWS_DAEMON_PID=""
NWS_DAEMON_LOG=""
NWS_DAEMON_OWNED=0

_stop_own_daemon() {
  trap - EXIT INT TERM
  if [ -n "$NWS_DAEMON_PID" ] && kill -0 "$NWS_DAEMON_PID" 2>/dev/null; then
    echo "==> stopping the example-spawned daemon (pid $NWS_DAEMON_PID)"
    kill "$NWS_DAEMON_PID" 2>/dev/null || true
    wait "$NWS_DAEMON_PID" 2>/dev/null || true
  fi
  NWS_DAEMON_PID=""
}

_exit_from_signal() {
  _stop_own_daemon
  exit 130
}

# _nws_daemon_up probes daemon liveness on the wire: connect to the control
# socket (port from config.json, else the 17424 default) and check that the
# raw `LIST` reply starts with `OK` (list_reply's `OK <count>`). Guarded to
# be safe under set -euo pipefail and to leave no leaked fd. bash /dev/tcp
# needs no nc. Connection refused or a non-OK reply = no reachable daemon.
_nws_daemon_up() {
  local port="17424" line="" cfg="$HOME/.config/nws/config.json"
  if [ -f "$cfg" ]; then
    port="$(sed -n 's/^[[:space:]]*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg" | head -1)"
    port="${port:-17424}"
  fi
  if ! { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null; then return 1; fi
  printf 'LIST\n' >&3
  IFS= read -r line <&3 || true
  exec 3>&- 2>/dev/null || true
  [[ "$line" == OK* ]]
}

ensure_daemon() {
  # Liveness probe: the raw LIST reply must start with `OK`. The exit code
  # is NOT a probe — every nws client command returns 0 even when the daemon
  # is unreachable (it prints an error and returns), which would make us
  # silently use a dead daemon and never spawn our own. And `nws list`'s
  # client strips the OK header, so only the wire reply carries it.
  if _nws_daemon_up; then
    echo "==> nws daemon already running — using it (never killed or restarted)"
    return 0
  fi
  NWS_DAEMON_LOG="/tmp/nws-example-${EXAMPLE_NAME}-daemon.log"
  "$NWS_BIN" service >"$NWS_DAEMON_LOG" 2>&1 &
  NWS_DAEMON_PID=$!
  NWS_DAEMON_OWNED=1
  echo "==> starting the example nws daemon (pid $NWS_DAEMON_PID; log: $NWS_DAEMON_LOG)"
  if [ "$NWS_HOLD" -eq 0 ]; then
    # EXIT/INT/TERM kill ONLY our own spawned pid; never anyone else's daemon
    trap _exit_from_signal INT TERM
    trap _stop_own_daemon EXIT
  fi
  local i
  for i in $(seq 1 50); do
    if _nws_daemon_up; then
      echo "==> daemon ready"
      return 0
    fi
    sleep 0.2
  done
  echo "WARN: the spawned daemon did not answer LIST with OK — continuing anyway" >&2
}
ensure_daemon

# --- registration -------------------------------------------------------------
# Skips when the workspace is already registered; a register race reply
# containing `ERROR already registered` counts as success. NEVER de-registers.
register_or_skip() {
  if "$NWS_BIN" list 2>/dev/null | grep -qxF "$WS"; then
    echo "==> $WS already registered — skipping registration"
    return 0
  fi
  local out rc
  out="$("$NWS_BIN" register . "$@" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] || grep -qF 'ERROR already registered' <<<"$out"; then
    echo "==> registered $WS"
    return 0
  fi
  echo "ERROR: nws register failed: $out" >&2
  return 1
}

# --- resolver copy (idempotent overwrite into the workspace folder) -----------
# The daemon spawns the resolver directly (no shell), so the copy must stay
# EXECUTABLE even if the source lacks +x (cp preserves the source mode).
copy_resolver() {
  cp "$1" "$WS/nws-resolver.sh"
  chmod +x "$WS/nws-resolver.sh"
  echo "==> resolver copied to $WS/nws-resolver.sh"
}

# --- clones: skip if the directory already exists (re-run friendly) -----------
clone_or_skip() {
  local branch="$1" url="$2" name="$3"
  if [ -d "$name" ]; then
    echo "==> $name already present — skipping clone"
    return 0
  fi
  git clone --depth 1 --branch "$branch" "$url" "$name"
}

# --- wait for nws to splice every resolver-emitted child ----------------------
# Polls the working flake.nix until the `= prev:` splice count >= expected,
# nudging with `touch flake.nix` (the daemon watches only the workspace ROOT,
# so a root ATTRIB event is the reliable nudge; byte-equal regen is skipped).
wait_for_splice() {
  local resolver="${1:-}" expected="${2:-}"
  if [ -n "$resolver" ] && [ -z "$expected" ]; then
    # expected omitted -> recompute it from the resolver over the finished
    # clones (same count the caller prints before waiting)
    expected="$(bash "$resolver" "$WS" | wc -l)"
  fi
  echo "==> waiting for all $expected packages to be spliced into flake.nix ..."
  local i have=0
  for i in $(seq 1 180); do
    # grep -c prints the count AND exits 1 on zero matches; `|| true` keeps
    # the substitution's exit status clean so HAVE is the bare "0" (an
    # `|| echo 0` here would append a second 0 and break the -ge check).
    have="$(grep -c '= prev:' "$WS/flake.nix" 2>/dev/null || true)"
    if [ "$have" -ge "$expected" ]; then break; fi
    touch "$WS/flake.nix" 2>/dev/null || true
    sleep 0.5
    if [ $((i % 20)) -eq 0 ]; then echo "    ...$have/$expected spliced so far"; fi
  done
  sleep 1   # let the daemon finish a regen after the last event
  touch "$WS/flake.nix" 2>/dev/null || true   # force one final regen
  sleep 1
  echo "==> flake.nix ready ($have/$expected spliced)"
}

# --- output helpers ------------------------------------------------------------
println() { printf '%s\n' "$*"; }

# --- end of run: hold (--hold) or exit; the EXIT trap stops our own daemon ----
example_done() {
  echo
  if [ "$NWS_HOLD" -eq 1 ]; then
    if [ -n "$NWS_DAEMON_PID" ]; then
      echo "==> --hold: keeping the example-spawned daemon (pid $NWS_DAEMON_PID) watching $WS"
      echo "    log: $NWS_DAEMON_LOG — Ctrl+C stops this script; the daemon keeps running."
      while true; do sleep 3600; done
    fi
    echo "==> --hold (no spawned daemon): your running daemon keeps watching — exiting."
    return 0
  fi
  if [ -n "$NWS_DAEMON_PID" ]; then
    echo "==> done — exiting; the example-spawned daemon (pid $NWS_DAEMON_PID) stops with it."
  else
    echo "==> done — exiting; your running nws daemon keeps watching $WS."
  fi
  echo "    The workspace stays registered — the next 'nws service' re-establishes it."
}