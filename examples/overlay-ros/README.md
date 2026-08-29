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
7. **injects a ROS dev shell** (`devShells.<system>.default`) into the
   workspace flake — the USER LAYER — so `cd $WS && nix develop` gives
   `roscore`, `roslaunch`, `rosrun` with `ROS_MASTER_URI` set and
   `ROS_PACKAGE_PATH` pointing at: (a) the ROS base env's `share/ros` and
   (b) every local clone's source dir. That way `rosrun`/`roslaunch` find
   your **locally cloned** packages directly from source — no need to bake
   them as built derivations. The devShell is written **below the
   `# /nws block` END marker**, inside the outputs return set, so it is
   ordinary user content and survives every nws regeneration,
8. **holds** — the workspace and daemon stay up and the script prints
   `cd $WS && nix develop`; press **Ctrl+C** to stop the daemon, unregister the
   workspace and delete the folder (the `clean` trap does it).

## Run

```bash
# from the example folder
cd <repo-root>/examples/overlay-ros
bash run.sh
```

It prints the generated `flake.nix` header and the number of spliced children,
then runs the build. After a successful build the script **holds**: the
daemon keeps watching the workspace and the folder stays on disk. Press
**Ctrl+C** to clean up (stop daemon, unregister, delete the workspace).

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

## The dev shell is a user layer (nws stays generic)

nws intentionally never emits a `devShell` — it owns only its marked **nws
block** in the flake (between `# nws block — managed by nws; do not edit` and
`# /nws block`: inputs, splice, `packages.<system>`, `default`), and knows
nothing about ROS or any ecosystem. The ROS dev shell is the **user's
responsibility** (e.g. you might use `devenv` instead — nws doesn't care).

This example demonstrates that layering: nws creates the workspace flake,
and `run.sh` injects a `devShells.<system>.default` built with
`nixpkgs.mkShell`, whose build input is the spliced set's **`ros-base`
`buildEnv`** (provides `roscore`/`roslaunch`/`rosrun`), with a shellHook that
sets `ROS_MASTER_URI` and `ROS_PACKAGE_PATH`. `ROS_PACKAGE_PATH` deliberately
points at the workspace's **local source trees** (all `package.xml` dirs) —
so `rosrun` finds your locally-cloned packages directly from source, without
requiring every bare-spliced child to build as a derivation (some monorepo
subpackages have no declared deps and would fail the debug-output split).

The devShell is injected **below the `# /nws block` END marker**, i.e. inside
the flake's `outputs` return set but outside the region nws owns. nws
regenerates only its own block on every fs event, so the devShell — like any
other user content in `flake.nix` — **survives regeneration**; only the block
above it (inputs, splice, packages) updates. Edit the devShell or add more
outputs down there at any time; the daemon leaves them alone.

## Note

The build compiles ROS packages from source (slow the first time; later runs are
served by the nix store cache). Consider `cachix use ros` to pull the
nix-ros-overlay binary cache for the *unmodified* dependencies — only your
src-overridden packages rebuild locally.