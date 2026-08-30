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
   `resolver.sh` — with `--dev-shell-packages ros-base,gazebo-ros-pkgs,xacro,
   robot-state-publisher`, which tells nws to generate a `devShells.<system>.
   default` too (see "The dev shell" below),
4. clones **exactly two** TurtleBot repos (**noetic** branches, matching the
   overlay pin):
   - `turtlebot3_simulations` — the **main roslaunch** package (provides
     `turtlebot3_gazebo` / `turtlebot3_empty_world.launch` that starts gazebo),
   - `turtlebot3` — the **modifiable underneath** package (provides
     `turtlebot3_description`, the URDF/xacro shown in the simulation).
   Every other dependency is pulled in automatically: the nix build downloads
   and builds gazebo, gazebo_ros, xacro, robot_state_publisher, all the
   message/service packages, etc.
5. waits for nws to discover the packages and generate `flake.nix` — the
   generated flake splices every cloned package (src-override) **and** carries
   the nws-generated devShell in its managed block,
5b. **switches the devShell to PATCH mode** and adds the gazebo-GUI layer:
   run.sh appends a user devShell (below the block's END marker, carrying the
   nws devShell block markers) whose shellHook hands gzclient a closure-ABI
   mesa + the xcb Qt plugin — so the gazebo window renders even on hosts whose
   system glibc is newer than the overlay pin's (see the GUI-quirk note below),
6. runs **`nix build`** with no arguments (the generated flake's
   `packages.<system>.default` is a `buildEnv` aggregating every spliced child;
   best-effort — a failure here does not block `nix develop`),
7. **holds** — the workspace and daemon stay up and the script prints the
   launch instructions; press **Ctrl+C** to stop the daemon, unregister the
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

### Why every nix command needs `NIXPKGS_ALLOW_INSECURE=1 --impure`

The gazebo stack depends on `freeimage`, which this nixpkgs pin marks
**insecure** and refuses to evaluate. The gate lives inside the **overlay
flake's own nixpkgs import** — i.e. code outside this workspace's flake — so
no flake-local `permittedInsecurePackages` can lift it for the packages the
example needs (turtlebot3_gazebo's spliced child, and the devShell's gazebo
env). The only mechanism that reaches it is nixpkgs' documented env var,
which requires `--impure`:

```bash
NIXPKGS_ALLOW_INSECURE=1 nix develop --impure    # shell
NIXPKGS_ALLOW_INSECURE=1 nix build --impure       # (run.sh already does this)
```

`run.sh` already runs its build this way; you only need it for your own
`nix develop`/`nix build` invocations.

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

After `run.sh` holds (workspace ready), run in terminals (the hold keeps
the daemon but you don't need it for the sim):

```bash
# terminal A — the ROS master
export TURTLEBOT3_MODEL=burger        # or waffle / waffle_pi
cd <ws> && NIXPKGS_ALLOW_INSECURE=1 nix develop --impure
roscore

# terminal B — start gazebo with the virtual turtlebot
export TURTLEBOT3_MODEL=burger
cd <ws> && NIXPKGS_ALLOW_INSECURE=1 nix develop --impure
roslaunch turtlebot3_gazebo turtlebot3_empty_world.launch

# terminal C — drive it
roslaunch turtlebot3_teleop turtlebot3_teleop_key.launch

# terminal D — the simple test-drive node (optional; wants B running for odom)
roslaunch turtlebot3_gazebo turtlebot3_simulation.launch
```

Everything the launch needs comes from the **nws-generated dev shell env**: a
`buildEnv` over the spliced children (the *clones*, built from your local
source — listed first so they win every merged file) plus
`ros-base`, `gazebo-ros-pkgs` (the metapackage containing gazebo plugins,
ros, msgs and dev), `xacro` and `robot-state-publisher`. `turtlebot3_drive`
(the **C++** node in terminal D) ships compiled inside that env — built from
your cloned `turtlebot3_simulations` — so `roslaunch` resolves it exactly
like a built workspace; no source-dir symlinking needed.

You now have a gazebo window with a virtual TurtleBot (URDF from
`turtlebot3-description`) whose odometry/TF update as you teleop.

> On systems whose *global* glibc is newer than the overlay pin's (notably
> NixOS after a system update), the gazebo GUI's OGRE can't create a GLX
> visual: glvnd dlopens the system mesa, whose `libgallium` demands the newer
> glibc, and `gzclient` segfaults — while `gzserver` keeps running headless.
> `run.sh` covers this automatically (step 5b above): it switches the nws
> devShell into PATCH mode and adds a user-owned shellHook that exports
> `LD_LIBRARY_PATH`/`LIBGL_DRIVERS_PATH` pointing at `pkgsN.mesa` and
> `QT_QPA_PLATFORM=xcb` — nws still manages the env binding, the GUI fix stays
> user territory.

### Proving nws is doing the work

Your **local** `turtlebot3/turtlebot3_description` is the one gazebo uses, not
the upstream overlay package. The dev-shell env lists the spliced children
**first**, and buildEnv's collision resolution keeps the first-listed path, so
the clone builds (compiled from your local source) win over any overlay
original that sibling packages propagate. Edit e.g.
`urdf/turtlebot3_burger.urdf.xacro` (change a `<material>` colour), save, then
relaunch terminal B — the change shows in the running gazebo, proving the local
splice is live (rebuilds are cached, so this is fast after the first rebuild).

### Known upstream quirk (turtlebot3 package bug)

`turtlebot3_gazebo`'s launch uses `$(find xacro)`, `$(find gazebo_ros)` and
`$(find robot_state_publisher)`, but its `package.xml` **only declares**
`gazebo, gazebo_ros, geometry_msgs, nav_msgs, roscpp, sensor_msgs, std_msgs,
tf, turtlebot3_description` — i.e. **`xacro` and `robot_state_publisher` are
undeclared launch-time dependencies**, and so (worse) is **`gazebo_plugins`**:
the ROS1 model-plugin package (`libgazebo_ros_diff_drive.so` — the `/cmd_vel`
subscriber and `/odom` publisher — plus the laser/imu/camera plugins) is a
sibling of `gazebo_ros`, which ships only the api/paths **server** plugins.
Without `gazebo_plugins` the robot **spawns with no controller**: nothing
subscribes to `/cmd_vel` and there is no `/odom` or `/scan` — and the launch
does not fail, so it's easy to miss. This is an upstream `turtlebot3_simulations`
bug, not an nws issue. The example's dev shell covers all three by listing
`xacro`, `robot-state-publisher` and — via the `gazebo-ros-pkgs` metapackage —
`gazebo-plugins` explicitly (a bare `ros-base` dev shell would hit
`RLException: ... package 'xacro' not found`).

> Teleop: `turtlebot3_teleop` (with `turtlebot3_teleop_key.launch`) is a
> subpackage of the already-cloned `turtlebot3` repo — the resolver discovers it
> recursively, so it's spliced too, within the two-clone limit.

## The dev shell: generated by nws, standard pattern, no env manipulation

nws stays generic — it knows nothing about ROS — but it *does* generate a
devShell when the workspace asks for one. Registering with
`--dev-shell-packages <a,b,c>` (or setting `"devShellPackages": [...]` in
`~/.config/nws/config.json`) makes nws emit a `devShells.<system>.default`
**inside its managed block**, in the plain nix-ros-overlay shape:

```nix
devShells.x86_64-linux.default = let
  pkgsN = import inputs.nixpkgs { system = "x86_64-linux"; };
  env = spliced0.buildEnv {
    name = "nws-dev-env";
    ignoreCollisions = true;         # spliced children vs overlay originals
    paths = [                        # children FIRST → local clones win
      spliced0.turtlebot3
      spliced0.turtlebot3-bringup
      # ...every spliced child...
      spliced0.ros-base
      spliced0.gazebo-ros-pkgs
      # ...the --dev-shell-packages extras...
    ];
  };
in pkgsN.mkShell {
  name = "nws-dev-shell";
  packages = [ env ];
};
```

Note what's *not* there: **no `shellHook` and no `export`s**. The packages'
own setup hooks wire `ROS_PACKAGE_PATH`, `GAZEBO_PLUGIN_PATH`, `CMAKE_PREFIX
_PATH`, etc.; the env is just the same spliced inputs nws manages. The two
deviations from the textbook example are deliberate and documented:

- `ignoreCollisions = true` — children are src-overrides built against the
  base scope, so a sibling child's propagated deps can contain the **original
  overlay build** of another child (e.g. the clone `turtlebot3-bringup` *and*
  the overlay `turtlebot3-bringup` reachable through `turtlebot3-example`'s
  package.xml deps). One env holding two builds of the same package would
  otherwise fail with a buildEnv collision.
- children listed **first** — buildEnv keeps the first-listed path on a
  collision, so the local clone builds win over those propagated originals
  (that's what makes the "proving nws is doing the work" edit demo work).

### User devShell wins; nested managed block (PATCH mode)

nws never overwrites a devShell you wrote yourself. If the flake already has a
`devShells.*` attr in the user zone (below the `# /nws block` END marker),
nws skips its own emission (and logs why). To let nws manage the **env
binding** of *your* shell — keep your `name`/`shellHook`/non-ROS packages,
have nws maintain the ROS env — put the markers inside your devShell's `let`:

```nix
devShells.x86_64-linux.default = let
  pkgsN = import inputs.nixpkgs { system = "x86_64-linux"; };
  # nws devShell block — managed by nws; do not edit
  # /nws devShell block
in pkgsN.mkShell {
  packages = [ env ];          # env comes from the nws-managed region above
  shellHook = '' ... '';       # your user-owned additions stay yours
};
```

nws fills the marked region with the `env = spliced0.buildEnv {...}` binding
(children first, `ignoreCollisions`, plus your `--dev-shell-packages` extras)
on every regeneration. That's the supported way to add non-ROS packages
(`pkgs.colcon`, …) or a shellHook on top of the managed env.

## Note

The build compiles ROS packages from source (slow the first time; later runs are
served by the nix store cache). Consider `cachix use ros` to pull the
nix-ros-overlay binary cache for the *unmodified* dependencies — only your
src-overridden packages rebuild locally.