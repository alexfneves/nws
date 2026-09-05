# nws overlay example (overlay-python / nixpkgs python312Packages)

End-to-end demonstration of a **python nix overlay**: register a folder with
nixpkgs's own `python312Packages` as the overlay, clone two pure-python
modules, and have nws splice your local clones into that package set — with a
managed `nix develop` devShell on top.

## Prerequisites

- `nws` **installed** — the scripts resolve it via `$NWS` (env override) or
  `command -v nws`, and refuse to run when it's missing:
  ```bash
  nix profile install .#main          # from the nws repo — or:
  nix build .#main && export PATH="$PWD/result/bin:$PATH"
  ```
- `nix` with flakes enabled, `git`

## Why nixpkgs `python312Packages`?

Dedicated python-overlay flakes were checked and rejected for this example:

- **`cachix/nixpkgs-python`** exposes `packages.<system>` keyed **by
  interpreter version** (e.g. a `python-312` attr). Splicing a module would
  mean splicing the *interpreter itself* — cloning CPython and 15+ minute
  builds, for a module-level demo.
- **`nix-community/poetry2nix`**'s useful overlay entry,
  `overlays.default`, is an overlay **function**, not an attrset — nws's
  base resolution reads a *set* of package attrs and can't turn a function
  into one (`poetry2nix`'s `packages.<system>` contains the CLI tool, not
  python modules).

What remains is the canonical, always-available python package set: **nixpkgs
itself**, under `legacyPackages.x86_64-linux.python312Packages` — thousands
of `python3.12-*` derivations, one per pypi project, sharing the same
interpreter and dependency lattice. That is exactly a package *set* the nws
overlay backend can read and splice. (Verified at plan time:
`nix eval --raw github:NixOS/nixpkgs#legacyPackages.x86_64-linux.python312Packages.black.name`
→ `python3.12-black-26.5.1`.)

## What it does

`run.sh` sets up **the current folder** as an nws workspace — no temp
workspace, nothing is deleted, and the folder is never de-registered. It:

1. resolves the installed `nws` binary and checks the daemon: if one is
   already running it is **used as-is** (never killed or restarted);
   otherwise a daemon is spawned for this run and stopped again on exit (see
   "Daemon policy and `--hold`" below),
2. copies `resolver.sh` to `./nws-resolver.sh` and registers the current
   folder as an **overlay** workspace:
   ```bash
   nws register . \
     --overlay github:NixOS/nixpkgs \
     --attr-path legacyPackages.x86_64-linux.python312Packages \
     --nixpkgs github:NixOS/nixpkgs \
     --resolver "$PWD/nws-resolver.sh" \
     --dev-shell-packages black
   ```
   — see "The explicit `--nixpkgs` wire detail" below,
3. clones the two pure-python modules:
   **`psf/requests`** (default branch `main`) into `./requests` and
   **`python/typing_extensions`** at **tag `4.16.0`** (the exact version the
   nixpkgs pin expects — see the Drift caveat) into `./typing_extensions`
   — plain directories, no flake needed, since these packages are python
   *modules*, not flakes:
4. waits for nws to discover the clones and generate `flake.nix` — both are
   spliced in with src-overrides — then prints the generated flake, the
   `= prev:` splice lines, the `devShells` attr and the `nixpkgs` input line,
5. runs **`nix build`** with no arguments (the generated
   `packages.<system>.default` is a `buildEnv` of the spliced
   `requests` + `typing-extensions`; fast, cached). Best-effort: a failure
   is recorded and printed, never fatal — the generated flake itself must
   still **eval**,
6. prints what to do next (including the managed `nix develop` shell) and
   exits.

### The explicit `--nixpkgs` wire detail

With a single flake overlay (just `--overlay github:NixOS/nixpkgs`) and no
`--nixpkgs`, the generator's nixpkgs input cascade would emit

```nix
nixpkgs.follows = "overlay0/nixpkgs";
```

— the overlay is followed for `nixpkgs`. But the overlay **is** nixpkgs, and
the nixpkgs flake has **no `nixpkgs` input of its own to follow**, so the
generated flake would fail eval with "input ... has no 'nixpkgs' input".

Passing **`--nixpkgs github:NixOS/nixpkgs`** makes the generator emit the
direct input instead:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs";
  overlay0.url = "github:NixOS/nixpkgs";
};
```

That `nixpkgs` input is also what feeds `pkgsN` for the managed devShell — a
second reason the flag is part of the example, not optional.

### What the generated flake contains

Inside its managed block nws writes, for this workspace (proof greps in
`run.sh` match these):

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs";
  overlay0.url = "github:NixOS/nixpkgs";               # + # nws: marker
};
...
      requests = prev:
        if builtins.pathExists ./.nws/packages/requests.nix
        then ...
        else if (prev.requests or null) != null
        then prev.requests.overrideAttrs (final: { src = ./requests; })
        ...
      typing-extensions = prev: ... prev.typing-extensions.overrideAttrs
        (final: { src = ./typing_extensions; }) ...
```

`prev.requests.overrideAttrs (final: { src = ./requests; })` is the splice:
the derivation is the **overlay's** `python312Packages.requests` — all
dependencies (urllib3, charset_normalizer, …) inherited from
`python312Packages` exactly as pinned — only the **source tree** is swapped
for `./requests`. Pure-python modules survive the source swap trivially: the
build still uses the same `python3.12` interpreter and the same setup hooks,
only the code is yours.

The devShell attr is generated because of `--dev-shell-packages black`:

```nix
devShells.x86_64-linux.default = let
  pkgsN = import inputs.nixpkgs { system = "x86_64-linux"; };
  env = spliced0.buildEnv {
    name = "nws-dev-env";
    ignoreCollisions = true;
    paths = [
      spliced0.requests
      spliced0.typing-extensions
      spliced0.black
    ];
  };
in pkgsN.mkShell {
  name = "nws-dev-shell";
  packages = [ env ];
};
```

A `buildEnv` of your two spliced clones **plus** the extra `black` attr —
`devShells.<system>.default`, entered with a plain `nix develop`

### `resolver.sh`: the attr-name `_`→`-` mapping

`resolver.sh` (copied to `./nws-resolver.sh`) is the ecosystem-specific
piece. For every **first-level** directory holding python project metadata
(`pyproject.toml` or `setup.py`) it emits `<dirname>\t<dirname>` — with one
twist: nixpkgs names the attribute after the pypi project with `_` → `-`
(the `typing_extensions` *module*; the `typing-extensions` *attr*, exactly
like the ROS example's `turtlebot3_msgs` → `turtlebot3-msgs`). So:

```
requests              requests
typing-extensions     typing_extensions
```

`NAME` must be a key that actually exists in `python312Packages` — that is
what lets the src-override branch fire and inherit deps. If you clone a
different module (say `urllib3`), it maps to itself (`_`→`-` only if the
name has one) and splices the same way.

## Run

Run from your **own empty folder** — never from the nws repo root (the script
refuses to run there, so the repo's own `flake.nix` can never be clobbered):

```bash
mkdir demo && cd demo
bash <nws-repo>/examples/overlay-python/run.sh
```

It prints the generated `flake.nix`, the splice proof lines, the `devShells`
grep, runs the build, then prints what to do next.

**Re-running** the script in the same folder is safe: the registration is
skipped (`nws list` already shows the folder) and the existing clones are
reused (a pinned clone is best-effort moved back onto its tag). The script
never de-registers. If you want to point the workspace at
**different example parameters** (overlay URL, attrPath, dev shell extras), a
re-register does *not* update the old config — de-register first, then
re-run:

```bash
nws unregister "$PWD"
bash <nws-repo>/examples/overlay-python/run.sh
```

### Daemon policy and `--hold`

The script never kills or restarts a daemon it did not start. On entry it
probes the daemon's control socket (a raw `LIST` request; a live daemon
answers `OK <count>` — client exit codes can't be trusted here, they return
0 even against a dead daemon): if your own daemon is running it is used
as-is for the whole run. If none is reachable, a daemon is spawned for this
run (`nws service`, detached in its own session, log at
`/tmp/nws-example-overlay-python-daemon.log`); if the spawned daemon does
not come up within the readiness window the script **fails hard with the log
path** — a missing daemon is an error, never a silent continue. Without
`--hold` the spawned daemon is stopped again when the script exits. The
**registration persists** either way — the next `nws service` you start
re-establishes the workspace (clones and all).

To keep the spawned daemon alive so it keeps watching the folder:

```bash
bash <nws-repo>/examples/overlay-python/run.sh --hold   # or: HOLD=1 env
```

With `--hold` the script loops after printing the instructions. The spawned
daemon lives in its **own session** — a Ctrl+C stops the script and the
daemon keeps running (stop it later with `kill <pid>` — printed above — or
`pgrep -f 'nws service'`).

## Try it

```bash
cd <ws> && nix build      # same build run.sh just did (cached)
cd <ws> && nix develop    # managed devShell: black + spliced requests +
                          # typing-extensions on PATH
# within the shell:
python -c 'import requests, typing_extensions; print(requests.__version__)'
black --version
```

## Proving nws is doing the work

Your **local** `./requests` is the source `nix build` compiles, not the
upstream module the overlay pins. Edit
`requests/requests/__init__.py` (any trivial change — a comment, a log
line), save, and re-run:

```bash
cd <ws> && nix build
```

The derivation rebuilds from the **local clone** (the splice points `src` at
`./requests`), while its dependencies still come from `python312Packages` —
nixpkgs's pinned lattice with your source on top. Check the generated
`flake.nix` if in doubt: the
`prev.requests.overrideAttrs (final: { src = ./requests; })` line is the
splice.

## Drift caveat

The overlay pins nixpkgs (so `python312Packages` is some known revision),
and the example's **default flow** keeps every clone at the exact revision
that pin expects. `psf/requests` tracks its **default branch** `main`
(upstream moved it from `master` — requests has no `master` branch; `main`
is its default), while `python/typing_extensions` is pinned to **tag
`4.16.0`**, the exact version `python312Packages.typing-extensions` pins.

Why the typing_extensions pin: nws builds the src-overridden module with
nixpkgs's derivation, whose pinned version is hardcoded; nixpkgs's
`pythonMetadataCheckPhase` then compares that against the clone's own
metadata. typing_extensions `main` drifts past the pin (it reports
`4.16.1.dev0` while the pin is `4.16.0`) and that phase fails — the splice
itself worked, only the version drifted. run.sh's fresh clone lands directly
on the tag (`git clone --branch 4.16.0`), and a re-run that finds the folder
already cloned best-effort moves it back onto the tag.

**Bump the pin, bump the clone tag — and vice versa.** If you point the
workspace at a newer nixpkgs input (`register ... --nixpkgs <ref>`), or
nixpkgs itself bumps `typing-extensions`, update the `4.16.0` tag in run.sh's
`clone_or_skip` call to match (check the current pin with
`nix eval --raw github:NixOS/nixpkgs#legacyPackages.x86_64-linux.python312Packages.typing-extensions.version`).
The generated flake always evals regardless; run.sh records a build failure
non-fatally (a source-merge failure of a clone would show up there) so the
workspace stays inspectable.