#!/usr/bin/env bash
# nws end-to-end flake-backend example (flake-program-lib / sibling input override).
#
# The pair: hyprcursor (the PROGRAM — a cursor-format library AND its
# `hyprcursor-util` CLI) and hyprlang (the LIBRARY — hypr's config-language
# parsing library). Both are real nix flakes, and hyprcursor's own flake.nix
# declares hyprlang as a flake input with self-resolving follows:
#
#     hyprlang = {
#       url = "github:hyprwm/hyprlang";
#       inputs.systems.follows = "systems";
#       inputs.nixpkgs.follows = "nixpkgs";
#     };
#
# This example uses the FLAKE backend (no --overlay flags): nws registers
# both clones as path inputs and — because the hyprcursor child's input
# names were parsed and `hyprlang` matches a sibling directory — emits the
# sibling override `hyprcursor.inputs.hyprlang.url = "path:./hyprlang"`.
# The program then resolves the library from the LOCAL clone.
#
# Sets up ONLY the CURRENT folder (no temp workspace, no teardown):
#   1. ensure an nws daemon (use the user's if one is running; only spawn our
#      own when none is — see ../common.sh for the daemon policy and --hold)
#   2. register THIS folder — plain `nws register .` (flake backend, no
#      overlay flags)
#   3. clone the two repos into THIS folder:
#        hyprwm/hyprcursor  (branch main) -> ./hyprcursor
#        hyprwm/hyprlang    (branch main) -> ./hyprlang
#      the dir names MUST equal the flake input names — that is what lets
#      the sibling override fire (nws matches parsed input names against
#      sibling directories)
#   4. wait for the daemon to generate flake.nix and grep-ASSERT the sibling
#      override line (the whole point of this example)
#   5. build the two DELEGATED output attrs — there is deliberately NO bare
#      `nix build`: the flake backend delegates each child's <out>.<sys>
#      attrs under `<child>-<attr>` names and has no aggregated `.default`
#      (see the README). Best-effort, non-fatal.
#   6. print what to run next, then exit (or --hold to keep the spawned daemon)
#
# Run from your OWN empty folder (common.sh refuses the nws repo root):
#   mkdir demo && cd demo && bash <repo>/examples/flake-program-lib/run.sh
# Re-running in the same folder skips the registration; to point the workspace
# at different flags, de-register it first (see the README).

set -euo pipefail
EXAMPLE_NAME=flake-program-lib
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../common.sh"

# 2. register THIS folder — plain flake backend: no --overlay / --resolver /
# --attr-path flags (those select the OVERLAY backend; their absence is what
# makes nws pin the children as flake inputs and delegate their outputs).
# Idempotent: an already-registered workspace is skipped, never re-registered.
register_or_skip

# 3. clone the pair into the current folder. The first-level DIRECTORY NAMES
# must equal the flake INPUT names (hyprcursor, hyprlang) — nws parses each
# child's flake input names and matches them against sibling directories, and
# only a name match fires the sibling override.
clone_or_skip main https://github.com/hyprwm/hyprcursor.git hyprcursor
clone_or_skip main https://github.com/hyprwm/hyprlang.git hyprlang
echo "==> clones ready (hyprcursor@main, hyprlang@main)"

# 4. wait for the daemon to generate flake.nix with the sibling override.
# Registration triggers an immediate sync, and cloning the two dirs fires
# inotify events that re-sync — poll for the override line (a re-run finds it
# already in place). The `touch` nudges the root watcher (root-only inotify)
# once the clones exist.
echo "==> waiting for the daemon to generate flake.nix with the sibling override ..."
for i in $(seq 1 40); do
  [ -f flake.nix ] && grep -q 'hyprcursor.inputs.hyprlang' flake.nix && break
  sleep 0.5
done
touch flake.nix 2>/dev/null || true
sleep 1

# grep-ASSERT the sibling override — the demo point. A missing override means
# nws did not wire the program to the LOCAL library clone, so the example
# fails loudly instead of pretending.
OVERRIDE='hyprcursor.inputs.hyprlang.url = "path:./hyprlang"'
if ! grep -qF -- "$OVERRIDE" flake.nix; then
  echo
  echo "ERROR: the sibling override line is missing from $WS/flake.nix." >&2
  echo "This example demonstrates nws wiring the program's flake input to the" >&2
  echo "LOCAL library clone; without '$OVERRIDE' there is no sibling input" >&2
  echo "override and the demo makes no point." >&2
  echo >&2
  echo "Expected to find (in the generated inputs section):" >&2
  echo "    hyprcursor.url = \"path:./hyprcursor\";                       # child pin" >&2
  echo "    hyprcursor.inputs.hyprlang.url = \"path:./hyprlang\";      # <-- sibling override" >&2
  echo "    hyprlang.url = \"path:./hyprlang\";                          # child pin" >&2
  echo >&2
  echo "Actual flake.nix (head):" >&2
  sed -n '1,30p' "$WS/flake.nix" >&2
  echo >&2
  echo "Notes:" >&2
  echo "  * both clone dirs (hyprcursor, hyprlang) must exist as FIRST-LEVEL" >&2
  echo "    directories named exactly like the child flake's input names;" >&2
  echo "  * an old nws binary predates sibling-override emission — rebuild" >&2
  echo "    it (nix build .#main) and re-run; the flake backend regenerates." >&2
  exit 1
fi
echo "==> OK — sibling override present:  $OVERRIDE"

echo
echo "==> the generated flake.nix (pic — inputs + overriding sibling):"
sed -n '1,12p' "$WS/flake.nix"
echo "==> proof — nws wired the program to the LOCAL library clone:"
grep -n 'inputs.hyprlang' "$WS/flake.nix" || true

# 5. build the DELEGATED output attrs, best-effort and non-fatal (a failure
# here is recorded and printed — e.g. upstream master drifted past a pinned
# dep; see the drift caveat in the README). Explicitly NO bare `nix build`:
# the flake backend delegates each child's own <out>.<sys> attrs under
# `<child>-<attr>` names and there is no aggregated `packages.<sys>.default`
# (delegation collides with the children's own `default` attrs, so nws
# prefixes instead — see the README).
echo
echo "==> nix build .#packages.x86_64-linux.hyprlang-default    (the LIBRARY, from the local clone)"
set +e
nix build --extra-experimental-features 'nix-command flakes' .#packages.x86_64-linux.hyprlang-default 2>&1 | tail -15
HYPRLANG_EXIT=${PIPESTATUS[0]}
echo "==> hyprlang-default build finished (exit $HYPRLANG_EXIT)"
set -e

echo
echo "==> nix build .#packages.x86_64-linux.hyprcursor-default  (the PROGRAM, consuming the local hyprlang)"
set +e
nix build --extra-experimental-features 'nix-command flakes' .#packages.x86_64-linux.hyprcursor-default 2>&1 | tail -15
HYPRCURSOR_EXIT=${PIPESTATUS[0]}
echo "==> hyprcursor-default build finished (exit $HYPRCURSOR_EXIT)"
set -e

# 6. everything is set up — hand the workspace to the user.
# The registration persists: nws keeps the workspace in its config, so the
# next `nws service` you start re-establishes it (clones and all). Nothing is
# deleted and nothing is de-registered by this script.
echo
echo
echo "==> SUCCESS"
echo "==> Workspace registered and ready at:    $WS"
if [ "$NWS_DAEMON_OWNED" -eq 1 ]; then
  echo "==> Example nws daemon (pid $NWS_DAEMON_PID, log: $NWS_DAEMON_LOG)"
  echo "    It watches $WS until this script exits — re-run with --hold to keep it."
else
  echo "==> Using your running nws daemon — it keeps watching $WS."
fi
echo
echo "==> Try it:"
echo "    cd $WS && nix build .#packages.x86_64-linux.hyprlang-default"
echo "    cd $WS && nix build .#packages.x86_64-linux.hyprcursor-default"
echo "    # (there is NO bare 'nix build' here — the flake backend delegates"
echo "    #  attrs as <child>-<attr> and has no aggregated .default; see README)"
echo
echo "==> Prove nws is doing the work — the hyprcursor build used YOUR hyprlang:"
echo "    edit $WS/hyprlang/src/config.cpp (any trivial change, e.g. a comment),"
echo "    then re-run 'nix build .#packages.x86_64-linux.hyprcursor-default': "
echo "    the program rebuilds against the LOCAL library clone (the generated"
echo "    'hyprcursor.inputs.hyprlang.url = \"path:./hyprlang\"' line is the wire)."
echo
echo "==> Why the flake backend here: no overlay — both children ARE flakes."
echo "    nws pins them as path inputs and delegates their own outputs under"
echo "    packages.<sys>.<child>-<attr> (see the README for the naming)."
example_done