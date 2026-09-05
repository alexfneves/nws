# nws overlay example (overlay-flakes / Hyprland ecosystem)

End-to-end demonstration of an **overlay workspace whose packages are nix
flakes**: register a folder, clone a flaky package, and have nws splice your
local clone into the overlay's package set.

## Prerequisites

- `nws` **installed** — the scripts resolve it via `$NWS` (env override) or
  `command -v nws`, and refuse to run when it's missing:
  ```bash
  nix profile install .#main          # from the nws repo — or:
  nix build .#main && export PATH="$PWD/result/bin:$PATH"
  ```
- `nix` with flakes enabled, `git`, `curl` (README verification only)

## What "packages are flakes" means here

A plain overlay like `examples/overlay-ros` reads a *package set* (the ROS1
`legacyPackages` of the nix-ros-overlay) whose sources live inside one big
nixpkgs-style overlay repo. This example flips that: the configured overlay —
**`github:hyprwm/hyprlang`** — is a **nix flake** whose
`packages.<system>` attrs are themselves **separate flake repos of the
Hyprland ecosystem**. `hyprlang` (this example's whole package set) is a
small C++ config-language parsing library, and its own flake pins a
sibling-flake input — `hyprutils` — with self-resolving follows. So the
"dependency graph" of this overlay is ordinary **flake-to-flake inputs**, not
one shared nixpkgs attrset.

That is exactly the shape nws's overlay backend is built for. nws stays
generic: `--attr-path packages.x86_64-linux` says *where* the package set
lives in the overlay flake, the resolver says *which* attrs to splice, and
nws emits the splice — **dependencies are inherited from the overlay's own
flake wiring** (`hyprutils` resolves via the overlay's `hyprlang` flake input
chain), while the **source is your local clone**.

## What it does

`run.sh` sets up **the current folder** as an nws workspace — no temp
workspace, nothing is deleted, and the folder is never de-registered. It:

1. resolves the installed `nws` binary and checks the daemon: if one is
   already running it is **used as-is** (never killed or restarted); otherwise
   a daemon is spawned for this run and stopped again on exit (see "Daemon
   policy and `--hold`" below),
2. copies `resolver.sh` to `./nws-resolver.sh` and registers the current
   folder as an **overlay** workspace pointing at it —
   `--overlay github:hyprwm/hyprlang --attr-path packages.x86_64-linux
   --resolver "$PWD/nws-resolver.sh"`. Deliberately **no
   `--dev-shell-packages`**: the generated devShell env would be a `buildEnv`
   of this one library — a busy env that adds nothing for Hyprland's
   config-language lib, and leaving it out keeps the example's build light
   (a bare `nix develop` against the generated `packages` works fine when you
   want a shell),
3. clones **`hyprwm/hyprlang`** (default branch **`main`**) into `./hyprlang`
   — the example's *own* repo, cloned because the src-override is the point:
4. waits for nws to discover the clone and generate `flake.nix` — the
   generated flake splices `hyprlang` (src-override), then prints the
   generated flake and the splice line,
5. runs **`nix build`** with no arguments (the generated
   `packages.<system>.default` is a `buildEnv` of the spliced `hyprlang`;
   fast — a tiny C++ lib, ~1–2 min cold). Best-effort: a failure is recorded
   and printed, never fatal,
6. prints the "edit the clone, rebuild" proof and exits.

### What the generated flake contains

For this workspace nws writes, inside its managed block:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";   # or similar
  overlay0.url = "github:hyprwm/hyprlang";               # + # nws: marker
  ...
};
...
      hyprlang = prev:
        if builtins.pathExists ./.nws/packages/hyprlang.nix
        then prev.callPackage ./.nws/packages/hyprlang.nix { }
        else if (prev.hyprlang or null) != null
        then prev.hyprlang.overrideAttrs (final: { src = ./hyprlang; })
        ...
```

`prev.hyprlang.overrideAttrs (final: { src = ./hyprlang; })` is the splice:
the derivation is the **overlay's** hyprlang (all dependencies — `hyprutils`,
fetched through the overlay's `hyprlang` input follows — inherited as pinned
by the overlay flake's lock), only the **source tree** is swapped for
`./hyprlang`.

`resolver.sh` (copied to `./nws-resolver.sh`) is the ecosystem-specific piece:
for every **first-level** directory that owns its own `flake.nix` it emits
`<dirname>\t<dirname>` — here exactly `hyprlang\thyprlang`. That 1:1
dirname→attr rule is why no `_`→`-` mapping is needed (unlike the ROS
example): Hyprland repo names are already hyphenated, and the overlay's
package attr has the same name as the repo. A repo can still expose more than
one attr under the same source — `hyprlang` also has a `hyprlang-with-tests`
variant — those just aren't cloned/spliced here (the resolver emits one line
per *directory*, not per attr).

## Run

Run from your **own empty folder** — never from the nws repo root (the script
refuses to run there, so the repo's own `flake.nix` can never be clobbered):

```bash
mkdir demo && cd demo
bash <nws-repo>/examples/overlay-flakes/run.sh
```

It prints the generated `flake.nix`, the splice proof line, runs the build,
then prints what to do next.

**Re-running** the script in the same folder is safe: the registration is
skipped (`nws list` already shows the folder) and the existing clone is
reused. The script never de-registers. If you want to point the workspace at
**different example parameters** (overlay URL, attrPath, the flagship variant
below), a re-register does *not* update the old config — de-register first,
then re-run:

```bash
nws unregister "$PWD"
bash <nws-repo>/examples/overlay-flakes/run.sh
```

### Daemon policy and `--hold`

The script never kills or restarts a daemon it did not start. On entry it
probes the daemon's control socket (a raw `LIST` request; a live daemon
answers `OK <count>` — client exit codes can't be trusted here, they return
0 even against a dead daemon): if your own daemon is running it is used
as-is for the whole run. If none is reachable, a daemon is spawned for this
run (`nws service`, detached in its own session, log at
`/tmp/nws-example-overlay-flakes-daemon.log`); if the spawned daemon does
not come up within the readiness window the script **fails hard with the log
path** — a missing daemon is an error, never a silent continue. Without
`--hold` the spawned daemon is stopped again when the script exits. The
**registration persists** either way — the next `nws service` you start
re-establishes the workspace (clone and all).

To keep the spawned daemon alive so it keeps watching the folder:

```bash
bash <nws-repo>/examples/overlay-flakes/run.sh --hold   # or: HOLD=1 env
```

With `--hold` the script loops after printing the instructions. The spawned
daemon lives in its **own session** — a Ctrl+C stops the script and the
daemon keeps running (stop it later with `kill <pid>` — printed above — or
`pgrep -f 'nws service'`).

## Proving nws is doing the work

Your **local** `./hyprlang` is the source `nix build` compiles, not the
upstream package the overlay pins. Edit `hyprlang/src/config.hpp` (any
trivial change — a comment, a log line), save, and re-run:

```bash
cd <ws> && nix build
```

The derivation rebuilds from the **local clone** (the splice points `src` at
`./hyprlang`), while `hyprutils` and friends still resolve through the
overlay's flake inputs — the overlay's pinned dependency graph with your
source on top. Check the generated `flake.nix` if in doubt: the
`prev.hyprlang.overrideAttrs (final: { src = ./hyprlang; })` line is the
splice.

## Drift caveat

The overlay flake pins a lock of its packages' sources, but your clone is
`git clone --depth 1` of **`main` at clone time**. Hyprland repos move fast,
so the local source can drift past what the overlay's pinned dependency
versions expect (this is the same trade-off the ROS example makes with its
`noetic` branches, minus the branch pin here — Hyprland track `main`). nws
can't fix that: it just hands the source to the overlay's own derivation. If
the build breaks, check whether upstream `hyprlang`/`hyprutils` moved —
`git -C hyprlang pull`, or pin the clone to the commit the overlay's
flake.lock references. run.sh records a build failure non-fatally so the
workspace stays inspectable.

## OPTIONAL flagship variant (heavier build)

The base example uses `hyprlang` because it's a leaf-sized, fast-building
single attr — the smallest complete "overlay whose packages are flakes"
story. The **flagship** shape of the same idea is the workspace that powers
the whole compositor: use the **`hyprland`** flake as the overlay and splice
*its* package sources.

Register (after `nws unregister "$PWD"` if you ran the base example first):

```bash
nws register . \
  --overlay github:hyprwm/hyprland \
  --attr-path packages.x86_64-linux \
  --resolver "$PWD/nws-resolver.sh"
```

Clone the two flaky packages (note the **branch asymmetry** — the 
`xdg-desktop-portal-hyprland` flake only exists on **`master`**; verified:
`curl -sI https://raw.githubusercontent.com/hyprwm/xdg-desktop-portal-hyprland/master/flake.nix`
→ HTTP 200, while `main` 404s):

```bash
git clone --depth 1 --branch main   https://github.com/hyprwm/hyprland.git
git clone --depth 1 --branch master https://github.com/hyprwm/xdg-desktop-portal-hyprland.git
```

then splice as usual (touch `flake.nix` / re-register to retrigger a sync) and
build **only** the compositor — *not* the bare default, which would also pull
in the Qt-dependent `xdg-desktop-portal-hyprland`:

```bash
nix build .#packages.x86_64-linux.hyprland
```

Notes on this variant:

- it's a **much heavier** build (a full Wayland compositor, and
  `hyprland-with-tests` / `hyprland-debug` stay out of the picture on
  purpose), so it is presented here as the flagged upgrade path, not what
  run.sh does by default;
- `hyprland.cachix` supplies prebuilt binaries for the *unmodified*
  dependency graph — only your spliced clones rebuild (`cachix use hyprland`);
- the resolver needs no changes: `./hyprland/flake.nix` and
  `./xdg-desktop-portal-hyprland/flake.nix` are both first-level flakes, so
  it emits `hyprland\thyprland` and
  `xdg-desktop-portal-hyprland\txdg-desktop-portal-hyprland`.