#!/usr/bin/env bash
# nws overlay resolver example (overlay-python / nixpkgs python312Packages).
#
# Contract (nws): prints `NAME\tRELPATH` for every package to splice, where
#   NAME    = OVERLAY ATTRIBUTE name (a key that exists in the configured
#             attrPath's set — here legacyPackages.x86_64-linux.
#             python312Packages, so e.g. `requests`, `typing-extensions`)
#   RELPATH = local source dir, relative to the workspace root
#
# nws stays generic: it keys children by NAME and src-overrides `prev.NAME`,
# so NAME must be an attribute that ACTUALLY exists in the overlay for the
# src-override branch to fire (inheriting deps from python312Packages).
# The ecosystem-specific bit — mapping a git repo to its overlay attr — lives
# HERE.
#
# nixpkgs names python312Packages attrs after the pypi project with
# `_` -> `-` (the module `typing_extensions`; the nix attr `typing-extensions`).
# For every FIRST-LEVEL directory holding python project metadata
# (pyproject.toml or setup.py) we print `<hyphenated-dirname>\t<dirname>`.
#
# Hidden dirs are skipped: the `*` glob does not match dotdirs unless dotglob
# is set — an explicit guard keeps it robust either way.

root="$1"
for d in "$root"/*/; do
  [ -d "$d" ] || continue                    # unstatted glob -> no dirs
  name="${d#"$root"/}"
  name="${name%%/*}"
  case "$name" in .*) continue;; esac        # hidden dir (dotglob guard)
  [ -f "$d/pyproject.toml" ] || [ -f "$d/setup.py" ] || continue
  attr="${name//_/-}"                        # underscore -> hyphen attr name
  printf '%s\t%s\n' "$attr" "$name"
done