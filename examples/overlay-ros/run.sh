#!/usr/bin/env bash
# nws end-to-end overlay example (ROS / nix-ros-overlay).
#
# Runs, in ONE process (so the daemon stays alive the whole time):
#   1. start the nws daemon
#   2. create a temporary workspace folder
#   3. register it as an overlay workspace, pointing at this dir's resolver
#   4. clone a couple of TurtleBot repos into it
#   5. wait for nws to generate flake.nix
#   6. run `nix build` (bare)
#   7. delete the workspace and stop the daemon
#
# Use from the repo root's build artifacts:
#   from the project root:   result/bin/nws  (built via nix build .#main)
# This script is executed from inside the example folder, so it references the
# binary relative as ../result/bin/nws.

set -euo pipefail

# --- resolve paths relative to this script's location (no ~/gits hardcode) ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # examples/overlay-ros
# walk up until we find the repo root (a dir containing flake.nix and result/)
ROOT="$HERE"
while [ ! -e "$ROOT/result/bin/nws" ] && [ "$ROOT" != "/" ]; do
  ROOT="$(dirname "$ROOT")"
done
NWS="$ROOT/result/bin/nws"                            # built binary
RESOLVER="$HERE/resolver.sh"                          # our package.xml mapper

PORT=17424
WS="/tmp/nws_example_overlay_ws"
DAEMON_LOG="/tmp/nws_example_overlay_daemon.log"

clean() {
  set +e
  echo "==> cleaning up (unregister + stop daemon + rm workspace)"
  "$NWS" unregister "$WS" </dev/null >/dev/null 2>&1
  pkill -f "$NWS service" 2>/dev/null
  rm -rf "$WS"
}
trap clean EXIT INT TERM

echo "==> nws binary: $NWS  (exists: $([ -e "$NWS" ] && echo yes || echo NO))"
[ -f "$NWS" ] || { echo "FATAL: $NWS missing — run 'nix build .#main' from the repo root first"; exit 1; }

# 1. start the daemon (fresh)
pkill -f "$NWS service" 2>/dev/null || true
sleep 0.3
"$NWS" service >"$DAEMON_LOG" 2>&1 &
SVC_PID=$!
for i in $(seq 1 50); do
  if printf 'LIST\n' | nc -w 1 127.0.0.1 "$PORT" >/dev/null 2>&1; then break; fi
  sleep 0.2
done
echo "==> daemon started (pid $SVC_PID)"

# 2+3. create + register the workspace
rm -rf "$WS"
mkdir -p "$WS"
"$NWS" register "$WS" \
  --overlay github:lopsided98/nix-ros-overlay/ros1-25.05 \
  --attr-path legacyPackages.x86_64-linux.noetic \
  --resolver "$RESOLVER"
echo "==> registered $WS"

# 4. clone repos.
# Use the ROS1 `noetic` branches (nix-ros-overlay ros1-25.05 pins ROS1/noetic
# versions; cloning `master` would pull ROS2 source that src-overrides don't match).
cd "$WS"
git clone --depth 1 --branch noetic https://github.com/ROBOTIS-GIT/turtlebot3_msgs.git turtlebot3-msgs
git clone --depth 1 --branch noetic https://github.com/ROBOTIS-GIT/turtlebot3.git turtlebot3
echo "==> cloned repos (noetic branches)"
# 5. wait for nws to discover BOTH repos (msgs + the turtlebot3 monorepo's packages)
for i in $(seq 1 80); do
  if [ -f "$WS/flake.nix" ] && grep -q "turtlebot3_msgs\|turtlebot3-msgs" "$WS/flake.nix" \
     && grep -q "turtlebot3-bringup\|turtlebot3_bringup" "$WS/flake.nix"; then
    break
  fi
  # poke a file to ensure an fs event if the clone set hasn't settled
  sleep 0.5
done
sleep 1   # let the daemon finish a regen after the last event
# force one final regeneration (full clone set present now)
find "$WS" -name package.xml -exec touch {} \;
sleep 1
echo "==> generated flake.nix"
sed -n '1,8p' "$WS/flake.nix"
grep -c '= prev:' "$WS/flake.nix" | xargs echo "    spliced children:"

# 6. build (bare; default output aggregates all spliced children)
echo "==> nix build ..."
cd "$WS"
nix build --extra-experimental-features 'nix-command flakes' 2>&1 | tail -30

# 7. everything is up — hand the workspace to the user.
# The daemon keeps watching it (regenerating flake.nix on edits/clones) and
# the workspace stays on disk until the user presses Ctrl+C, at which point
# the clean() trap deletes the folder and stops the daemon.
echo
echo "==> SUCCESS"
echo "==> Workspace ready at:    $WS"
echo "==> Daemon running (pid: $SVC_PID) — watching it for changes."
echo "==> Try it:  cd $WS  &&  nix build"
echo "==> Press Ctrl+C to stop the daemon and delete the workspace."
while true; do
  sleep 3600
done