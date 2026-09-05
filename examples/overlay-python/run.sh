#!/usr/bin/env bash
# nws end-to-end overlay example (overlay-python / nixpkgs python312Packages).
#
# The python overlay: nixpkgs's own python312Packages set
# (legacyPackages.x86_64-linux.python312Packages). Dedicated python-overlay
# flakes were checked and rejected: cachix/nixpkgs-python keys its package
# set BY INTERPRETER VERSION (splicing would mean cloning CPython and 15+
# min builds), and poetry2nix's overlays.default is an overlay *function*,
# which nws's base resolution cannot turn into a package set. nixpkgs's
# python312Packages is the canonical always-available python package set.
#
# IMPORTANT wire detail: with a single flake overlay and no --nixpkgs, the
# generator would emit `nixpkgs.follows = "overlay0/nixpkgs"` — invalid,
# because the nixpkgs flake has no `nixpkgs` input of its own to follow.
# Passing `--nixpkgs github:NixOS/nixpkgs` makes the generator emit
# `inputs.nixpkgs.url` directly (and feeds pkgsN for the devShell).
#
# Sets up ONLY the CURRENT folder (no temp workspace, no teardown):
#   1. ensure an nws daemon (use the user's if one is running; only spawn our
#      own when none is — see ../common.sh for the daemon policy and --hold)
#   2. register THIS folder as an overlay workspace with the copied resolver
#      (+ --dev-shell-packages black: nws generates devShells.<system>.default
#      with a black shell env over the spliced children)
#   3. clone the two pure-python modules into THIS folder:
#        psf/requests (branch main)             -> ./requests
#        python/typing_extensions (branch main)  -> ./typing_extensions
#      (requests used to track `master`; upstream moved its default branch
#      to `main` — clone the current default for a stable pin)
#   4. wait for nws to generate flake.nix — both children spliced in via
#      `prev.<attr>.overrideAttrs (final: { src = ./<dir>; })`
#   5. run `nix build` (bare: the generated packages.<system>.default is a
#      buildEnv of the spliced modules) — best-effort, non-fatal
#   6. print what to run next, then exit (or --hold to keep the spawned daemon)
#
# Run from your OWN empty folder (common.sh refuses the nws repo root):
#   mkdir demo && cd demo && bash <repo>/examples/overlay-python/run.sh
# Re-running in the same folder skips the registration; to point the workspace
# at different flags, de-register it first (see the README).

set -euo pipefail
EXAMPLE_NAME=overlay-python
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../common.sh"

# 2. register THIS folder (idempotent; never de-registers). The resolver is
# copied into the folder first — nws calls it per sync, so the path passed on
# the wire must exist at registration time.
copy_resolver "$HERE/resolver.sh"
register_or_skip \
  --overlay github:NixOS/nixpkgs \
  --attr-path legacyPackages.x86_64-linux.python312Packages \
  --nixpkgs github:NixOS/nixpkgs \
  --resolver "$WS/nws-resolver.sh" \
  --dev-shell-packages black
#    ^ --dev-shell-packages black: nws generates devShells.<system>.default =
#      an env with black + the spliced children (see the devShell section in
#      the README). The explicit --nixpkgs is what makes the devShell's pkgsN
#      exist WITHOUT the invalid `nixpkgs.follows = "overlay0/nixpkgs"` wire
#      (the nixpkgs flake has no `nixpkgs` input of its own to follow).

# 3. clone the two pure-python modules into the current folder. Both are
# plain directories (no flake needed) — these packages are python MODULES,
# not flakes, so the src-override is what splices them in.
clone_or_skip main https://github.com/psf/requests.git requests
clone_or_skip main https://github.com/python/typing_extensions.git typing_extensions
echo "==> clones ready (requests@main, typing_extensions@main)"

# 4. wait for nws to splice the clones (the number of NAME<tab>RELPATH lines
# the resolver emits over the finished clones — requests + typing-extensions).
EXPECTED="$(bash "$WS/nws-resolver.sh" "$WS" | wc -l)"
echo "==> resolver emits $EXPECTED packages; waiting for the daemon to splice them all..."
wait_for_splice "$WS/nws-resolver.sh" "$EXPECTED"

echo
echo "==> the generated flake.nix (pic — inputs + splice):"
sed -n '1,60p' "$WS/flake.nix"
echo "==> proof — nws spliced the clones ('= prev:' lines are the splices):"
grep -n '= prev:' "$WS/flake.nix" || true
echo "==> the managed devShell attr is present:"
grep -n 'devShells' "$WS/flake.nix" || true
echo "==> and the nixpkgs input is a direct URL input (no follows cascade):"
grep -n 'nixpkgs' "$WS/flake.nix" | sed -n '1,3p' || true

# 5. build (bare — the generated default is a buildEnv of the spliced
# requests + typing-extensions) — best-effort: a failure here is recorded and
# printed, never fatal (the overlay must still EVAL — a source-merge failure
# of a clone would show up here; see the drift caveat in the README).
echo
echo "==> nix build ... (bare: default = buildEnv of the spliced python modules)"
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
echo "    cd $WS && nix develop        # managed devShell: black + the spliced"
echo "                                 # requests + typing-extensions on PATH"
echo "    # within it: python -c 'import requests, typing_extensions; print(requests.__version__)'"
echo "    #             black --version"
echo
echo "==> Prove nws is doing the work — the builds used YOUR clones:"
echo "    edit $WS/requests/requests/__init__.py (any trivial change, e.g. a comment),"
echo "    then re-run 'nix build': the derivation rebuilds from the LOCAL clone"
echo "    (the splice points src at ./requests; deps still come from python312Packages)."
echo
echo "==> Why nixpkgs python312Packages: dedicated python-overlay flakes are"
echo "    interpreter-version sets (cachix/nixpkgs-python — splicing means"
echo "    compiling CPython) or overlay FUNCTIONS nws can't turn into a package"
echo "    set (poetry2nix overlays.default). python312Packages is the canonical"
echo "    always-available python package set (see the README)."
example_done