# nws flake-backend example (flake-program-lib / sibling input override)

End-to-end demonstration of the **flake (non-overlay) backend**: register a
folder with nws, clone a program **and** a library — **both real nix flakes,
with the program's flake declaring the library as a flake input** — and have
nws wire the **sibling-input override** so the program resolves the library
from the **local clone**.

## Prerequisites

- `nws` **installed** — the scripts resolve it via `$NWS` (env override) or
  `command -v nws`, and refuse to run when it's missing:
  ```bash
  nix profile install .#main          # from the nws repo — or:
  nix build .#main && export PATH="$PWD/result/bin:$PATH"
  ```
- `nix` with flakes enabled, `git`

## Why this pair

The **program** side is **hyprcursor** — the Hyprland cursor-format library
*and* its `hyprcursor-util` CLI tool. The **library** side is **hyprlang** —
the official implementation library for the hypr config language that
hyprcursor parses at build time. Both are real flakes, and hyprcursor's own
`flake.nix` declares hyprlang as a flake input:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  systems.url = "github:nix-systems/default-linux";
  hyprlang = {
    url = "github:hyprwm/hyprlang";
    inputs.systems.follows = "systems";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

The `inputs.hyprlang.inputs.nixpkgs.follows = "nixpkgs"` /
`inputs.hyprlang.inputs.systems.follows = "systems"` lines are the
**self-resolving follows** — the pattern verified to work under nws's path
pinning: nws only overrides *where* the hyprlang input resolves from
(`path:./hyprlang`); the follows cascade (hyprlang's own `nixpkgs`/`systems`
inputs following hyprcursor's) lives inside the child flake and keeps working
unchanged.

## What it does

`run.sh` sets up **the current folder** as an nws workspace — no temp
workspace, nothing is deleted, and the folder is never de-registered. It:

1. resolves the installed `nws` binary and checks the daemon: if one is
   already running it is **used as-is** (never killed or restarted);
   otherwise a daemon is spawned for this run and stopped again on exit (see
   "Daemon policy and `--hold`" below),
2. registers the current folder with a **plain `nws register .`** — no
   `--overlay`/`--resolver`/`--attr-path` flags; their absence is what
   selects the **flake backend** (children are pinned as flake inputs and
   their outputs delegated, instead of being spliced into an overlay):
   ```bash
   nws register .
   ```
3. clones the pair into the folder:
   **`hyprwm/hyprcursor`** (default branch `main`) into `./hyprcursor` and
   **`hyprwm/hyprlang`** (default branch `main`) into `./hyprlang` — the
   directory names **must equal the flake input names**: nws parses each
   child's flake input names and matches them against sibling directories,
   and only a name match fires the override,
4. waits for the daemon to discover the clones and generate `flake.nix`,
   then **grep-asserts the sibling override line** (missing ⇒ the script
   prints the expected-vs-actual snippet and exits non-zero), prints the
   generated flake's head,
5. builds the two **delegated output attrs** — best-effort: a failure is
   recorded and printed, never fatal (see the Drift caveat):
   ```bash
   nix build .#packages.x86_64-linux.hyprlang-default
   nix build .#packages.x86_64-linux.hyprcursor-default
   ```
   — explicitly **no bare `nix build`**, see "Delegated output naming"
   below,
6. prints what to do next and exits.

## What the sibling override means

nws parses each child's flake input names (hyprcursor declares
`nixpkgs`, `systems`, **`hyprlang`**; hyprlang declares `nixpkgs`, `systems`,
`hyprutils`). The name **`hyprlang` is also a sibling directory**, so the
generator emits, right under hyprcursor's own pin:

```nix
inputs = {
  hyprcursor.url = "path:./hyprcursor";              # + # nws: github:hyprwm/hyprcursor
  hyprcursor.inputs.hyprlang.url = "path:./hyprlang";   # <-- sibling override
  hyprlang.url = "path:./hyprlang";                  # + # nws: github:hyprwm/hyprlang
};
```

Meaning: when the hyprcursor child's flake is evaluated, its `hyprlang`
input resolves from `./hyprlang` — the **local clone** — instead of
`github:hyprwm/hyprlang`. The program is built against **your** library.

What stays **unoverridden** is just as important:

- `hyprcursor.inputs.nixpkgs` and `hyprcursor.inputs.systems` are not
  siblings, so they keep resolving per the child's own lock (nws emits no
  line for them);
- `hyprlang.inputs.hyprutils` (hyprlang's own flake input) is not a
  sibling either, so it also stays per-lock;
- the child's *internal* follows cascade (`inputs.hyprlang.inputs.nixpkgs
  .follows = "nixpkgs"`, …) is part of the child flake and is copied along
  with the override, so the chain stays fully self-resolving.

That is the pattern that works under path pinning: nws re-targets exactly one
edge (program → library) and leaves every other resolution to the children's
own lock-follow machinery.

## Delegated output naming

The flake backend does not wrap children in an overlay — it pins them as
inputs and **delegates** each child's own outputs:

```
packages.<sys>.<child>-<attr>     # per child, per system, attr-name prefixed
```

Each child's `packages.<system>` set (hyprcursor: `default`, `hyprcursor`,
`hyprcursor-with-tests`; hyprlang: `default`, `hyprlang`, `hyprlang-with-tests`)
is re-exposed name-prefixed, so this workspace's buildable attrs are
`packages.x86_64-linux.hyprcursor-default`, `...hyprcursor-hyprcursor`,
`...hyprlang-default`, … .

There is **no aggregated `packages.<sys>.default`** — that's by design: both
children define their own `default` output attr, so delegation prefixes
(`hyprcursor-default`, `hyprlang-default`) instead of colliding. That is why
the example (and the README) never use bare `nix build` in this workspace:
bare `nix build` builds `packages.<sys>.default`, which does not exist here
(it fails with "attribute 'packages.x86_64-linux.default' missing"). Build
the delegated attrs explicitly.

## Run

Run from your **own empty folder** — never from the nws repo root (the script
refuses to run there, so the repo's own `flake.nix` can never be clobbered):

```bash
mkdir demo && cd demo
bash <nws-repo>/examples/flake-program-lib/run.sh
```

It prints the generated `flake.nix`, the sibling-override proof grep, runs
both delegated builds, then prints what to do next.

**Re-running** the script in the same folder is safe: the registration is
skipped (`nws list` already shows the folder) and the existing clones are
reused. The script never de-registers. If you want to point the workspace at
**different example parameters**, a re-register does *not* update the old
config — de-register first, then re-run:

```bash
nws unregister "$PWD"
bash <nws-repo>/examples/flake-program-lib/run.sh
```

### Daemon policy and `--hold`

The script never kills or restarts a daemon it did not start. On entry it
probes with `nws list`: if your own daemon is running it is used as-is for the
whole run. If none is reachable, a daemon is spawned for this run
(`nws service`, log at `/tmp/nws-example-flake-program-lib-daemon.log`);
without `--hold` it is stopped again when the script exits. The
**registration persists** either way — the next `nws service` you start
re-establishes the workspace (clones and all).

To keep the spawned daemon alive so it keeps watching the folder:

```bash
bash <nws-repo>/examples/flake-program-lib/run.sh --hold   # or: HOLD=1 env
```

With `--hold` the script loops after printing the instructions; Ctrl+C stops
the script and the daemon it spawned keeps running.

## Try it

```bash
cd <ws> && nix build .#packages.x86_64-linux.hyprlang-default
cd <ws> && nix build .#packages.x86_64-linux.hyprcursor-default
ls result/bin/hyprcursor-util   # the CLI the hyprcursor package ships
# (remember: no bare `nix build` — see "Delegated output naming")
```

## Proving nws is doing the work

Your **local** `./hyprlang` is the library the hyprcursor build compiles,
not the upstream repo resolved from the hyprcursor flake's own input. Check
the generated `flake.nix` in doubt: the
`hyprcursor.inputs.hyprlang.url = "path:./hyprlang";` line is the wire.
Edit `hyprlang/src/config.cpp` (any trivial change — a comment, a
log line), save, and re-run:

```bash
cd <ws> && nix build .#packages.x86_64-linux.hyprcursor-default
```

The hyprcursor derivation rebuilds against the **local library clone** (the
input override points hyprlang at `./hyprlang`), while everything else —
hyprcursor's `nixpkgs`/`systems` and hyprlang's `hyprutils` — still resolves
per the children's own lock/follows chain.

## Drift caveat

Both repos are fast-moving leaf repositories, and this example's **default
flow** keeps every clone at its **default branch `main`** — the inputs nws
does *not* override (`nixpkgs`, `systems`, `hyprutils`) resolve per the
children's own lock files, but the two workspace children themselves track
live `main`. If upstream drift bites (e.g. hyprcursor@main demands a newer
hyprlang than the cloned `hyprlang` provides, or a dep moved), the `-default`
build fails — run.sh records that failure **non-fatally**, the workspace
stays inspectable, and the generated flake always evals (the failure is a
build-time mismatch, not a malformed workspace).

The fix when drift bites is to **pin the tags** like the overlay-python
example does: point the `clone_or_skip` call at a released tag that builds
green (check with `nix flake metadata`/your own `nix build`), e.g.

```bash
clone_or_skip main https://github.com/hyprwm/hyprlang.git hyprlang v0.6.8
```

Note the override only swaps the **source**: dependency resolution still
follows the children's own flake wiring, so a pinned pair is as stable as the
children's own lock files.