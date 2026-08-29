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
# Philosophy: nws is GENERIC. It owns only the substitution machinery in the
# flake (inputs, splice, packages.<system>, default). It never emits a
# devShell and knows nothing about ROS. The dev shell is the USER's layer —
# here run.sh injects it once after nws generates. Because nws regenerates
# flake.nix on fs events, a later regeneration drops it (expected); re-inject
# by re-running this script.
#
# Use from the repo root's build artifacts:
#   from the project root:   result/bin/nws  (built via nix build .#main)

set -euo pipefail

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
# Use the ROS1 `noetic` branches (nix-ros-overlay ros1-25.05 pins ROS1/noetic
# versions; cloning `master` would pull ROS2 source that src-overrides don't match).
cd "$WS"
git clone --depth 1 --branch noetic https://github.com/ROBOTIS-GIT/turtlebot3_msgs.git turtlebot3-msgs
git clone --depth 1 --branch noetic https://github.com/ROBOTIS-GIT/turtlebot3.git turtlebot3
echo "==> cloned repos (noetic branches)"

# 5. wait for nws to discover BOTH repos (msgs + the turtlebot3 monorepo's packages)
for i in $(seq 1 120); do
  if [ -f "$WS/flake.nix" ] \
     && grep -q "turtlebot3_msgs\|turtlebot3-msgs" "$WS/flake.nix" \
     && grep -q "turtlebot3-bringup\|turtlebot3_bringup" "$WS/flake.nix" \
     && [ "$(grep -c '= prev:' "$WS/flake.nix")" -ge 2 ]; then
    break
  fi
  # poke an fs event so a late clone/checkout is noticed
  find "$WS" -name package.xml -exec touch {} \; 2>/dev/null || true
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

###############################################################################
# 6b. USER LAYER: inject a ROS dev shell into the managed flake.
#
# nws owns only the substitution part and never emits a devShell. This is the
# user's responsibility — demonstrated here by layering a devShell on top.
# nws regenerates flake.nix on each fs event, so a later regeneration drops
# this block (that is expected); re-run this script to re-inject.
###############################################################################
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
  # runs later with no $WS available). Build a colon-joined quoted list.
  local d
  while IFS= read -r d; do
    srcs+=":\"${d%/*}\""
  done < <(find "$WS" -name package.xml -type f 2>/dev/null | sort -u)

  cat <<EOF
    $mark
    devShells.$sys.default = let
      pkgsN = import inputs.nixpkgs { system = "$sys"; };
      env = spliced0.buildEnv {
        name = "nws-dev-env";
        paths = [ spliced0.ros-base ];
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

inject_devshell() {
  local f="$WS/flake.nix"
  [ -f "$f" ] || return 1
  local block
  block="$(build_devshell_block "$DEV_MARK" "$SYS")"
  # replace-idempotent: strip ANY existing devShell output block (marked or
  # stale — including old `//`-shaped ones) by deleting every line from a
  # `devShells.` attribute through its matching closing brace, then insert the
  # fresh block before the LAST closing "  };" of the outputs attrset.
  python3 - "$f" "$block" <<'PYEOF'
import re, sys
f, block = sys.argv[1], sys.argv[2]
s = open(f).read()
# remove any existing devShells.<sys>.default = ... ; block (balanced)
lines = s.split("\n")
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if re.match(r"^    devShells\.[A-Za-z0-9_-]+\.default =", line):
        depth = 0
        start = i
        # consume through the matching "    };" at the same nesting as "default = let"
        while i < len(lines):
            depth += lines[i].count("{") - lines[i].count("}")
            if depth <= 0 and re.match(r"^    };", lines[i]):
                break
            i += 1
        i += 1  # skip the closing line too
        continue
    out.append(line)
    i += 1
s = "\n".join(out) + "\n"
# insert block before the LAST 2-space closing line of outputs ("  };\n}")
idx = s.rfind("  };\n}")
if idx < 0:
    print("ANCHOR MISSING", file=sys.stderr); sys.exit(1)
s = s[:idx] + block + "\n" + s[idx:]
open(f, "w").write(s)
PYEOF
}

# after injecting, assert the flake has exactly one devShell with the ++ shape
assert_devshell_ok() {
  local n b
  n=$(grep -c 'devShells.x86_64-linux.default' "$WS/flake.nix" || true)
  b=$(grep -c 'paths = \[ spliced0.ros-base \];' "$WS/flake.nix" || true)
  if [ "$n" != "1" ] || [ "$b" != "1" ]; then
    echo "WARN: devShell inject assertion failed (found devShell=$n, ros-base-shape=$b)"
    return 1
  fi
  return 0
}

# inject, retrying until the flake is stable (daemon may still be settling
# regens and briefly write the minimal {} form which has no anchor)
for _t in $(seq 1 10); do
  inject_devshell
  assert_devshell_ok && { INJ_OK=1; break; }
  sleep 1
done
if [ "${INJ_OK:-0}" != "1" ]; then
  echo "WARN: dev shell injection failed (flake kept regenerating)"
fi

# 7. everything is up — hand the workspace to the user.
# NOTE: nws regenerates flake.nix on fs events and rewrites the WHOLE file,
# so a re-run of the daemon / a real workspace edit will drop the dev shell.
# That is expected: the dev shell is a USER layer. Re-inject it after any
# regeneration by running the inject snippet below (we keep it printed here;
# Ctrl+C still cleans up).
echo
echo
echo "==> SUCCESS"
echo "==> Workspace ready at:    $WS"
echo "==> Daemon running (pid: $SVC_PID) — watching it for changes."
echo "==> Try it:  cd $WS  &&  nix develop"
echo "==> NOTE: the devShell is a USER LAYER — nws does not own it. nws"
echo "    regenerates flake.nix on any fs event, which drops it. Re-inject"
echo "    after a regeneration by re-running this script (it restarts the"
echo "    daemon), or paste the devShells block from the inject function"
echo "    above into $WS/flake.nix yourself."
echo "==> Press Ctrl+C to stop the daemon and delete the workspace."
while true; do
  sleep 3600
done