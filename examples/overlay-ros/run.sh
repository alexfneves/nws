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
#   7. inject a ROS dev shell (USER LAYER on the managed flake), then HOLD;
#      pressing Ctrl+C unregisters, stops the daemon and deletes the folder
#
# Philosophy: nws is GENERIC. It owns only its marked nws block in the flake
# (the region between `# nws block — managed by nws; do not edit` and
# `# /nws block`: inputs, splice, packages.<system>, default) and never emits
# a devShell or knows anything about ROS. Everything else in flake.nix — a
# description, nixConfig, and any user output attr written below the block's
# END marker, like this dev shell — is ordinary USER content that nws
# byte-preserves across regenerations. So the devShell is injected ONCE, in
# its permanent home below `# /nws block`, and survives the daemon's updates
# instead of fighting them.
#
# Use from the repo root's build artifacts:
#   from the project root:   result/bin/nws  (built via nix build .#main)

set -euo pipefail

# This script uses bashisms (local, $'\n', arrays). Running it via `sh run.sh`
# (dash) silently breaks the injection. Require bash explicitly.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: run this script with bash:  bash $0" >&2
  exit 1
fi

# --- resolve paths relative to this script's location (no ~/gits hardcode) ---
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # examples/overlay-ros
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
  # disarm INT/TERM/EXIT while clean runs so a Ctrl+C during cleanup does not
  # re-trigger the trap (which caused an endless cascade of clean() calls).
  trap - INT TERM EXIT
  set +e
  echo "==> cleaning up (unregister + stop daemon + rm workspace)"
  "$NWS" unregister "$WS" </dev/null >/dev/null 2>&1
  pkill -f "$NWS service" 2>/dev/null
  rm -rf "$WS"
  pkill -f "$NWS service" 2>/dev/null
  exit 0
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

# 2+3. create + register the workspace (idempotent: unregister first if stale)
rm -rf "$WS"
mkdir -p "$WS"
"$NWS" unregister "$WS" </dev/null >/dev/null 2>&1 || true
"$NWS" register "$WS" \
  --overlay github:lopsided98/nix-ros-overlay/ros1-25.05 \
  --attr-path legacyPackages.x86_64-linux.noetic \
  --resolver "$RESOLVER"
echo "==> registered $WS"

# 4. clone repos.
# Exactly TWO clones:
#   - turtlebot3_simulations: the MAIN roslaunch package — provides
#     turtlebot3_gazebo with turtlebot3_empty_world.launch (starts gazebo).
#   - turtlebot3: the modifiable UNDERNEATH package — provides
#     turtlebot3_description (the URDF/xacro). Edit its materials/geometry and
#     the change is visible in the running gazebo simulation.
# Everything else (gazebo, gazebo_ros, xacro, robot_state_publisher, all msg/
# srv deps, the turtlebot3_msgs used by the model, ...) is pulled in
# automatically: the nix build downloads/builds those dependencies. Use the
# ROS1 `noetic` branches (ros1-25.05 pins ROS1/noetic; `master` is ROS2).
cd "$WS"
git clone --depth 1 --branch noetic https://github.com/ROBOTIS-GIT/turtlebot3_simulations.git turtlebot3-simulations
git clone --depth 1 --branch noetic https://github.com/ROBOTIS-GIT/turtlebot3.git turtlebot3
echo "==> cloned repos (noetic branches)"

# 5. wait for nws to discover the FULL clone set (this is the number of
# NAME<tab>RELPATH lines the resolver emits over the finished clones), so the
# generated flake splices every package — a partial set would silently fall
# back to upstream packages for the missing ones.
EXPECTED=$(bash "$RESOLVER" "$WS" | wc -l)
echo "==> resolver emits $EXPECTED packages; waiting for the daemon to splice them all..."
for i in $(seq 1 180); do
  HAVE=$(grep -c '= prev:' "$WS/flake.nix" 2>/dev/null || echo 0)
  if [ "$HAVE" -ge "$EXPECTED" ]; then break; fi
  # The daemon watches ONLY the workspace ROOT (inotify is not recursive):
  # deep file changes (touching package.xml inside a clone) wake nothing.
  # Touch the root's own flake.nix instead — an ATTRIB/CLOSE_WRITE event on
  # a root entry that always fires. Byte-equal skip makes it harmless.
  touch "$WS/flake.nix" 2>/dev/null || true
  sleep 0.5
  if [ $((i % 20)) -eq 0 ]; then echo "    ...$HAVE/$EXPECTED spliced so far"; fi
done
sleep 1   # let the daemon finish a regen after the last event
# force one final regeneration (full clone set present now)
touch "$WS/flake.nix" 2>/dev/null || true
sleep 1
echo "==> generated flake.nix"
sed -n '1,8p' "$WS/flake.nix"
grep -c '= prev:' "$WS/flake.nix" 2>/dev/null | xargs echo "    spliced children:"

###############################################################################
# 6b. USER LAYER: inject a ROS dev shell into the (user-owned) workspace flake.
# (Injected FIRST — right after children are discovered — so a parallel
# `nix develop` can enter immediately; the slow bare-splice build runs after.)
DEV_MARK="# nws-dev-shell (user layer, injected by run.sh)"
SYS="x86_64-linux"

build_devshell_block() {
  local mark="$1" sys="$2"
  # Dev shell = ROS tooling (ros-base buildEnv: roscore/roslaunch/rosrun) + the
  # workspace's LOCAL SOURCE dirs on ROS_PACKAGE_PATH. Pointing ROS_PACKAGE_PATH
  # at the source trees (rather than at built derivations) is what makes
  # rosrun/roslaunch find your local packages — WITHOUT forcing every bare
  # spliced child to build (some monorepo subpackages have no declared deps,
  # so a full derivation build can fail; source pathing avoids that entirely).
  local srcs=""
  # every package.xml dir under the workspace — find yields ABSOLUTE paths;
  # bake the package dirs into ROS_PACKAGE_PATH at inject time (the shellHook
  # runs later with no $WS available). Avoid process substitution so it works
  # under `sh`/dash too.
  local d
  while IFS= read -r d; do
    srcs+=":\"${d%/*}\""
  done <<EOSRC
$(find "$WS" -name package.xml -type f 2>/dev/null | sort -u)
EOSRC

  cat <<EOF
    $mark
    devShells.$sys.default = let
      # pkgsN is ONLY used for mkShell (a plain nixpkgs shell builder). The
      # env itself is spliced0.buildEnv over the OVERLAY's packages: ros-base
      # gives roscore/roslaunch/rosrun; gazebo, gazebo-ros, xacro and
      # robot-state-publisher give the launch-time $(find ...) deps that
      # turtlebot3_gazebo's launch uses but does NOT declare.
      #
      # Insecurity gate: gazebo needs nixpkgs' insecure freeimage, and the
      # gate lives in the OVERLAY flake's own nixpkgs import — no flake-local
      # permittedInsecurePackages can reach it in a PURE eval. Make sure to
      # enter the shell with:
      #   NIXPKGS_ALLOW_INSECURE=1 nix develop --impure
      # (the same mechanism run.sh already uses for `nix build` below).
      pkgsN = import inputs.nixpkgs { system = "$sys"; };
      env = spliced0.buildEnv {
        name = "nws-dev-env";
        # The local children (turtlebot3-gazebo, turtlebot3-description,
        # turtlebot3, ...) are deliberately NOT built here — they are served
        # to ROS directly from the workspace's own source trees via
        # ROS_PACKAGE_PATH ($srcs), keeping the "edit the URDF and see it in
        # gazebo" demo live.
        paths = [
          spliced0.ros-base
          spliced0.gazebo
          spliced0.gazebo-ros
          spliced0.xacro
          spliced0.robot-state-publisher
        ];
      };
    in pkgsN.mkShell {
      buildInputs = [ env ];
      shellHook = ''
        export ROS_MASTER_URI=http://localhost:11311
        export ROS_PACKAGE_PATH="\${env}/share/ros${srcs}"
        echo "ROS dev shell ready: rosrun/roslaunch"
      '';
    };
EOF
}

# Insert the devShell immediately AFTER the "# /nws block" END marker line, so
# it lands inside the outputs return set — the stable user-owned ground below
# the marker that nws regenerations never touch. Idempotent via the marker
# guard (a reused workspace keeps the injection). Pure bash, dash-safe, no
# python3.
inject_devshell() {
  local f="$WS/flake.nix"
  [ -f "$f" ] || return 1
  grep -qF "$DEV_MARK" "$f" && return 0   # already injected (idempotent)
  local block
  block="$(build_devshell_block "$DEV_MARK" "$SYS")"
  [ -n "$block" ] || return 1
  local anchor total out
  anchor="$(grep -n '^# /nws block$' "$f" | tail -1 | cut -d: -f1)"
  total="$(wc -l < "$f")"
  [ -n "$anchor" ] && [ "$anchor" -gt 0 ] || return 1
  out="$f.tmp"
  head -n "$anchor" "$f" > "$out"
  printf '%s\n\n' "$block" >> "$out"
  tail -n "$((total-anchor))" "$f" >> "$out"
  mv "$out" "$f"
}

inject_devshell
if grep -qF "$DEV_MARK" "$WS/flake.nix" 2>/dev/null; then
  echo "==> devShell injected below the nws block END marker — it survives regeneration"
else
  echo "WARN: dev shell injection failed (no '# /nws block' anchor found)"
fi

# 6. build (bare; default output aggregates all spliced children) — best-effort.
# The default buildEnv aggregates every bare-spliced child; some monorepo
# subpackages have no declared deps and fail the debug-output split. That does
# NOT block the dev shell (injected above), so do NOT let a build failure abort
# the script (pipefail would) — the dev shell and `nix develop` are the point.
#
# Insecure-package gate: turtlebot3_gazebo (a spliced child) depends on the
# gazebo stack, which needs nixpkgs' insecure `freeimage`. The gate lives in
# the OVERLAY's own nixpkgs import — flake-level `permittedInsecurePackages`
# cannot reach it. The documented nixpkgs mechanism is NIXPKGS_ALLOW_INSECURE
# + --impure, which every nixpkgs import in the eval honors. `nix develop`
# needs the same treatment (see the banner below).
cd "$WS"
echo "==> nix build ... (NIXPKGS_ALLOW_INSECURE=1 --impure: lifts the freeimage gate for the overlay's internal nixpkgs)"
set +e
NIXPKGS_ALLOW_INSECURE=1 nix build --impure --extra-experimental-features 'nix-command flakes' 2>&1 | tail -20
NIX_BUILD_EXIT=${PIPESTATUS[0]}
echo "==> nix build finished (exit $NIX_BUILD_EXIT) — continuing regardless"
set -e

# 7. everything is up — hand the workspace to the user.
# nws regenerates ONLY its own block on fs events; the user's devShell and the
# file's closing braces live outside it and persist. Edit the devShell (or add
# more outputs / devenv) below the "# /nws block" line at any time — the
# daemon will leave your content alone while it keeps updating its block.
echo
echo
echo "==> SUCCESS"
echo "==> Workspace ready at:    $WS"
echo "==> Daemon running (pid: $SVC_PID) — watching it for changes."
echo
echo "==> Run the GAZEBO simulation (see README):"
echo "    # The dev shell needs the same insecure-allow as the build:"
echo "    #   NIXPKGS_ALLOW_INSECURE=1 nix develop --impure"
echo "    # (the freeimage gate lives in the overlay's internal nixpkgs and can"
echo "    # only be lifted via the env var + --impure, not via flake content)"
echo "    export TURTLEBOT3_MODEL=burger   # or waffle / waffle_pi"
echo "    cd $WS && NIXPKGS_ALLOW_INSECURE=1 nix develop --impure   # into the ROS dev shell"
echo "    roscore                                 # terminal A: master"
echo "    roslaunch turtlebot3_gazebo turtlebot3_empty_world.launch"
echo "        # terminal B: gazebo starts with the virtual turtlebot"
echo "    roslaunch turtlebot3_teleop turtlebot3_teleop_key.launch"
echo "        # terminal C: drive it (arrow keys)"
echo
echo "==> The two local clones are: turtlebot3 (URDF/description) +"
echo "    turtlebot3_simulations (main gazebo launch). Edit e.g."
echo "    $WS/turtlebot3/turtlebot3_description/urdf/turtlebot3_burger.urdf.xacro"
echo "    (change a <material> colour) and rerun the launch — the change is"
echo "    visible in the running simulation, proving your spliced package is"
echo "    the one gazebo uses."
echo "==> All other deps (gazebo, gazebo_ros, xacro, robot_state_publisher,"
echo "    msgs, ...) are installed automatically by the nix build."
echo
echo "==> Press Ctrl+C to stop the daemon and delete the workspace."
while true; do
  sleep 3600
done
