#!/usr/bin/env bash
# nws end-to-end overlay example (overlay-flakes / Hyprland ecosystem).
#
# What "packages are flakes" means here: the configured OVERLAY is itself a
# nix flake whose package set (packages.<system>) is populated by the flake
# repos of the Hyprland ecosystem — hyprlang itself is a flake declaring
# hyprutils as a sibling-flake input. nws stays generic: it reads the
# overlay's attrPath via --attr-path and src-overrides whatever the resolver
# names, so every spliced child's dependencies are inherited from the
# overlay's own flake wiring (no dependency re-parsing).
#
# Sets up ONLY the CURRENT folder (no temp workspace, no teardown):
#   1. ensure an nws daemon (use the user's if one is running; only spawn our
#      own when none is — see ../common.sh for the daemon policy and --hold)
#   2. register THIS folder as an overlay workspace with the copied resolver.
#      Deliberately NO --dev-shell-packages: the generated devShell env would
#      be a buildEnv of this one lib — nothing to add for a config-language
#      library, and keeping it out keeps the build light (see the README).
#   3. clone the hyprlang repo (default branch `main`) into THIS folder
#   4. wait for nws to generate flake.nix — the `hyprlang` child spliced in
#   5. run `nix build` (bare: the generated packages.<system>.default is a
#      buildEnv of the spliced hyprlang) — best-effort, non-fatal
#   6. print what to run next, then exit (or --hold to keep the spawned daemon)
#
# Run from your OWN empty folder (common.sh refuses the nws repo root):
#   mkdir demo && cd demo && bash <repo>/examples/overlay-flakes/run.sh
# Re-running in the same folder skips the registration; to point the workspace
# at different flags, de-register it first (see the README).

set -euo pipefail
EXAMPLE_NAME=overlay-flakes
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../common.sh"

# 2. register THIS folder (idempotent; never de-registers). The resolver is
# copied into the folder first — nws calls it per sync, so the path passed on
# the wire must exist at registration time.
copy_resolver "$HERE/resolver.sh"
register_or_skip \
  --overlay github:hyprwm/hyprlang \
  --attr-path packages.x86_64-linux \
  --resolver "$WS/nws-resolver.sh"
#    ^ NO --dev-shell-packages on purpose: the devShell env would be a
#      buildEnv of the spliced lib — a busy env that adds nothing for a C++
#      config-language library (and the README's optional flagship variant
#      notes how to use a plain `nix develop` against the generated set).

# 3. clone the flaky package into the current folder.
# Exactly ONE clone: hyprwm/hyprlang, default branch `main`. This is the
# example's OWN repo — the src-override is the whole point: your local clone
# is spliced over the overlay's upstream hyprlang (deps still follow the
# overlay's flake pin), so the build IS the local source.
clone_or_skip main https://github.com/hyprwm/hyprlang.git hyprlang
echo "==> clones ready (hyprlang@main)"

# 4. wait for nws to splice the clone (the number of NAME<tab>RELPATH lines
# the resolver emits over the finished clones — exactly `hyprlang\thyprlang`).
EXPECTED="$(bash "$WS/nws-resolver.sh" "$WS" | wc -l)"
echo "==> resolver emits $EXPECTED packages; waiting for the daemon to splice them all..."
wait_for_splice "$WS/nws-resolver.sh" "$EXPECTED"

echo
echo "==> the generated flake.nix (pic — inputs + splice):"
sed -n '1,50p' "$WS/flake.nix"
echo "==> proof — nws spliced the clone (the '= prev:' line is the splice):"
grep -n '= prev:' "$WS/flake.nix" || true

# 5. build (bare — the generated default is a buildEnv of the spliced
# hyprlang) — best-effort: a failure here is recorded and printed, never
# fatal (e.g. upstream master drifted past the overlay pin's deps — see the
# drift caveat in the README).
echo
echo "==> nix build ... (bare: default = buildEnv of the spliced hyprlang)"
set +e
nix build --extra-experimental-features 'nix-command flakes' 2>&1 | tail -25
NIX_BUILD_EXIT=${PIPESTATUS[0]}
echo "==> nix build finished (exit $NIX_BUILD_EXIT) — continuing regardless"
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
echo "    cd $WS && nix build          # same build run.sh just did (cached)"
echo "    ls result/lib                # the compiled hyprlang shared library"
echo
echo "==> Prove nws is doing the work — the build used YOUR clone:"
echo "    edit $WS/hyprlang/src/config.hpp (any trivial change, e.g. a comment),"
echo "    then re-run 'nix build': the derivation rebuilds from the LOCAL clone"
echo "    (the splice points src at ./hyprlang; deps still come from the overlay)."
echo
echo "==> Why no dev shell: the devShell env would be a buildEnv of this one"
echo "    lib — nothing to add for a config-language library, and it keeps the"
echo "    example build light. The generated packages.* attrs are all there if"
echo "    you want plain 'nix develop' against the spliced set."
example_done