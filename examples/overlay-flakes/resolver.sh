#!/usr/bin/env bash
# nws overlay resolver example (overlay-flakes / Hyprland ecosystem).
#
# Contract (nws): prints `NAME\tRELPATH` for every package to splice, where
#   NAME    = OVERLAY ATTRIBUTE name (a key that exists in the configured
#             attrPath's set — here the overlay flake's packages.<system>)
#   RELPATH = local source dir, relative to the workspace root
#
# What makes this example special: the OVERLAY is itself a nix flake whose
# package attrs are themselves flake repos of the Hyprland ecosystem (they
# declare their own flake inputs — hyprlang input-pins hyprutils). Each clone
# in the workspace is its OWN flake, so the attr name it must be spliced
# under equals its directory name: `hyprlang` lives in ./hyprlang and the
# overlay exposes packages.<system>.hyprlang.
#
# For every FIRST-LEVEL directory that owns its own flake.nix we emit
# `<dirname>\t<dirname>`. A `_`->`-` mapping isn't needed for this ecosystem
# (Hyprland repo names are already hyphenated) but the dirname->attr rule is
# what keeps the 1:1 clone->attr story; multi-attr variants of a repo (e.g.
# hyprlang's `hyprlang-with-tests`) are noted in the README.
#
# Hidden dirs are skipped: the `*` glob does not match dotdirs unless dotglob
# is set — an explicit guard keeps it robust either way.

root="$1"
for f in "$root"/*/flake.nix; do
  [ -f "$f" ] || continue                    # unstatted glob -> not a flake
  name="${f#"$root"/}"
  name="${name%%/*}"
  case "$name" in .*) continue;; esac        # hidden dir (dotglob guard)
  printf '%s\t%s\n' "$name" "$name"
done