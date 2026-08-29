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
4. clones **exactly two** TurtleBot repos (**noetic** branches, matching the
   overlay pin):
   - `turtlebot3_simulations` — the **main roslaunch** package (provides
     `turtlebot3_gazebo` / `turtlebot3_empty_world.launch` that starts gazebo),
   - `turtlebot3` — the **modifiable underneath** package (provides
     `turtlebot3_description`, the URDF/xacro shown in the simulation).
   Every other dependency is pulled in automatically: the nix build downloads
   and builds gazebo, gazebo_ros, xacro, robot_state_publisher, all the
   message/service packages, etc.
5. waits for nws to discover the packages and generate `flake.nix`,
6. runs **`nix build`** with no arguments (the generated flake's
   `packages.<system>.default` is a `buildEnv` aggregating every spliced child),
7. **injects a ROS dev shell** (`devShells.<system>.default`) into the
   workspace flake — the USER LAYER — so `cd $WS && nix develop` gives
   `roscore`, `roslaunch`, `rosrun`, `gazebo`, `rviz` with `ROS_MASTER_URI`
   set and `ROS_PACKAGE_PATH` covering: (a) a `buildEnv` of the spliced set's
   `ros-base` + `gazebo` + `gazebo-ros` + `xacro` + `robot-state-publisher` +
   `turtlebot3-gazebo` + `turtlebot3-description` + `turtlebot3` (so all
   `$(find ...)` used by the launch resolve), and (b) every local clone's
   source dir. The devShell is written **below the `# /nws block` END
   marker**, inside the outputs return set, so it is ordinary user content
   and survives every nws regeneration,
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

## Running the gazebo simulation

After `run.sh` holds (workspace ready), run in three terminals (the hold keeps
the daemon but you don't need it for the sim):

```bash
# terminal A — the ROS master
export TURTLEBOT3_MODEL=burger        # or waffle / waffle_pi
cd <ws> && nix develop
roscore

# terminal B — start gazebo with the virtual turtlebot
export TURTLEBOT3_MODEL=burger
cd <ws> && nix develop
roslaunch turtlebot3_gazebo turtlebot3_empty_world.launch

# terminal C — drive it (needs one extra clone, see below)
roslaunch turtlebot3_teleop turtlebot3_teleop_key.launch
```

You now have a gazebo window with a virtual TurtleBot (URDF from
`turtlebot3-description`) whose odometry/TF update as you teleop.

### Proving nws is doing the work

Your **local** `turtlebot3/turtlebot3_description` is the one gazebo uses, not
the upstream overlay package. Edit e.g. `urdf/turtlebot3_burger.urdf.xacro`
(change a `<material>` colour), save, then relaunch terminal B — the change
shows in the running gazebo, proving the local splice is live.

### Known upstream quirk (turtlebot3 package bug)

`turtlebot3_gazebo`'s launch uses `$(find xacro)`, `$(find gazebo_ros)` and
`$(find robot_state_publisher)`, but its `package.xml` **only declares**
`gazebo, gazebo_ros, geometry_msgs, nav_msgs, roscpp, sensor_msgs, std_msgs,
tf, turtlebot3_description` — i.e. **`xacro` (and `robot_state_publisher`) are
undeclared launch-time dependencies**. This is an upstream
`turtlebot3_simulations` bug, not an nws issue. The example's dev shell pulls
`xacro`/`robot-state-publisher` in anyway (they're normal overlay packages), so
the launch works; a bare `ros-base` dev shell would hit
`RLException: ... package 'xacro' not found`.

> Teleop: `turtlebot3_teleop` (with `turtlebot3_teleop_key.launch`) is a
> subpackage of the already-cloned `turtlebot3` repo — the resolver discovers it
> recursively, so it's spliced too, within the two-clone limit.

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