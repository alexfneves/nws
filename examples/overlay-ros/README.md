# nws overlay example (ROS / nix-ros-overlay)

End-to-end demonstration of an **overlay workspace**: register a folder and have
nws splice your own clones of overlay packages into a configured package set.

## Prerequisites

- `nix` with flakes enabled
- `nc` (`netcat`), `git`
- The nws binary built at the repo root:
  ```bash
  cd <repo-root>
  nix build .#main    # → ./result/bin/nws
  ```

## What it does

`run.sh` must be run as a **single process** (so the nws daemon stays alive for
the whole run). From the repo root it:

1. starts the nws daemon,
2. creates a temporary workspace `$WS`,
3. registers it as an **overlay** workspace pointing at this folder's
   `resolver.sh`,
4. clones the TurtleBot `turtlebot3_msgs` and `turtlebot3` repos (**noetic**
   branches — ROS1 versions matching the overlay pin) into the workspace,
5. waits for nws to discover the packages and generate `flake.nix`,
6. runs **`nix build`** with no arguments (the generated flake's
   `packages.<system>.default` is a `buildEnv` aggregating every spliced child),
7. deletes the workspace and stops the daemon.

## Run

```bash
# from the example folder
cd <repo-root>/examples/overlay-ros
bash run.sh
```

It prints the generated `flake.nix` header and the number of spliced children,
then runs the build. Exit 0 + a `SUCCESS` line means `nix build` completed with
no errors.

## How it works

- `resolver.sh` is the ecosystem-specific piece. nws stays generic: it calls the
  script once per sync and treats each `NAME\tRELPATH` stdout line as a child to
  splice. Here it reads every `package.xml` and emits the package's **overlay
  attribute name** (underscores → hyphens, matching nix-ros-overlay's
  `turtlebot3-msgs` keys) plus its directory.
- nws src-overrides each NAME: it emits `prev.NAME.overrideAttrs (final: { src =
  ./RELPATH; })`, so the package's **dependencies are inherited from the overlay**
  — no dependency re-parsing in nws.
- Because the local source must match the overlay's pinned deps, the repos are
  cloned from their **ROS1 `noetic` branches**. Cloning `master` would pull ROS2
  source that doesn't match the ROS1/noetic overlay and fails to build.

## Note

The build compiles ROS packages from source (slow the first time; later runs are
served by the nix store cache). Consider `cachix use ros` to pull the
nix-ros-overlay binary cache for the *unmodified* dependencies — only your
src-overridden packages rebuild locally.