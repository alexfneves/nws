#!/usr/bin/env bash
# nws overlay resolver example (ROS / nix-ros-overlay).
#
# Contract (nws): prints `NAME\tRELPATH` for every package to splice, where
#   NAME    = OVERLAY ATTRIBUTE name (the key that exists in the configured
#             attrPath's set, e.g. `turtlebot3-msgs`)
#   RELPATH = local source dir, relative to the workspace root
#
# nws stays generic: it keys children by NAME and src-overrides `prev.NAME`,
# so NAME must be an attribute that ACTUALLY exists in the overlay for the
# src-override branch to fire (inheriting deps). The ecosystem-specific bit —
# mapping a git repo / package.xml to its overlay attr name — lives HERE.
#
# nix-ros-overlay exposes attrs as the ROS <name> with `_` -> `-`
# (package.xml says turtlebot3_msgs; the overlay attr is turtlebot3-msgs).
# We print the hyphenated <name> for every package.xml found.

root="$1"
name_from_xml() { sed -n 's:.*<name>\([^<]*\)</name>.*:\1:p' "$1" | head -1; }

find "$root" -name package.xml -type f | while read -r f; do
  d="$(dirname "$f")"
  rel="${d#"$root"}"
  rel="${rel#/}"
  [ -z "$rel" ] && rel="."
  xmlname="$(name_from_xml "$f")"
  [ -z "$xmlname" ] && continue
  # underscore -> hyphen so `prev.<NAME>` matches the nix-ros-overlay attr.
  attr="${xmlname//_/-}"
  printf '%s\t%s\n' "$attr" "$rel"
done