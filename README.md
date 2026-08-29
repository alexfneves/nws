# nws — Nix Workspace Root Manager

`nws` is a single Odin CLI binary that manages **one generated `flake.nix` per
workspace folder**, turning a directory of sibling repo checkouts into a
coherent Nix workspace — without ever touching the repos themselves.

A **daemon** (`nws service`) watches each registered workspace with inotify and
(re)generates its root `flake.nix` whenever repos are cloned, moved, or
removed:

- every cloned subfolder becomes a local input: `path:./<name>`,
- **sibling dependencies are wired locally**: if repo A's flake declares an
  input named B, and B is also cloned in the workspace, the generated flake
  adds an override so A builds against your local B instead of its locked
  GitHub URL,
- when a clone is removed, its input falls back to the canonical GitHub URL
  recorded in a `# nws:` marker comment,
- children's outputs (`packages`, `devShells`, `apps`, `checks`) are delegated
  under `<child>-` prefixed names, grouped per system.

A tiny localhost TCP control socket lets the `register` / `unregister` / `list`
client commands talk to the running daemon.

## Why

Normally, hacking on a library and its consumers together means either
publishing to GitHub constantly or hand-editing every consumer's `flake.nix`.
nws gives you a third option: clone everything side by side in one workspace
folder, and the generated root flake pins the whole graph locally. Your repos'
own flakes stay byte-for-byte pristine — `git status` stays clean, commits
never contain workspace-local hacks.

```console
$ cd ~/workspaces/mytree
$ git clone github.com/hyprwm/hypridle  # depends on hyprutils
$ git clone github.com/hyprwm/hyprutils
$ nws register .                        # daemon regenerates ./flake.nix
$ nix build .#packages.x86_64-linux.hypridle-hypridle   # builds against local hyprutils
```

## Build & install

Build the binary from the flake:

```bash
nix build .#main      # or just: nix build .
# output symlink: ./result  →  ./result/bin/nws
```

Install it into your Nix profile:

```bash
nix profile install .#main
```

This also installs shell completions (bash/zsh/fish) and the systemd user
unit.

Install the systemd **user** unit so the daemon starts on login:

```bash
mkdir -p ~/.config/systemd/user
cp ./result/share/systemd/user/nws.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now nws
systemctl --user status nws
```

The unit runs `%h/.nix-profile/bin/nws service` and restarts on failure
(`Restart=on-failure`). If you install `nws` somewhere else, edit the
`ExecStart` line accordingly.

## CLI usage

```
nws service [--config-path PATH]  run the daemon (watches workspaces, serves the control socket)
nws register [PATH]     add a workspace (default: current directory)
                        overlay options: --overlay URL --attr-path ATTR
                        [--overlay-attr NAME] [--no-flake] [--nixpkgs URL]
                        [--resolver SCRIPT] [--dev-shell-packages A,B,C]
nws unregister [PATH]   remove a workspace
nws list                list registered workspaces
nws help                show this help
```

For overlay workspaces, `--dev-shell-packages a,b,c` (or
`"devShellPackages": [...]` in config.json) makes nws generate and maintain a
`devShells.<system>.default` **inside its managed block**, in the standard
nix-ros-overlay shape: a `mkShell` wrapping a `buildEnv` env over every
spliced child (listed first, so local clones win merged collisions) plus the
listed overlay attrs, with `ignoreCollisions = true`. No shellHook or env
variables are emitted — the packages' own setup hooks do the wiring. A user
`devShells.*` written below the `# /nws block` END marker takes precedence
(nws skips and logs); adding the `# nws devShell block — managed by nws; do
not edit` / `# /nws devShell block` markers inside your own devShell's `let`
makes nws manage just that env binding instead.

`register` / `unregister` / `list` are client commands: they connect to the
daemon's control socket on the **default** port (`127.0.0.1:17424`), so the
daemon must be running first. If you start the daemon with a custom
`--config-path` that sets a different `port`, talk to it with
`printf 'REGISTER <path>\n' | nc 127.0.0.1 <port>` (paths are
percent-encoded on the wire).

Daemon logs (watch add/remove, flake generation, connection handling) go to
stderr; set `NWS_LOG=0` to silence them.

```bash
nws service &                    # start the daemon with the default config
nws register ~/workspaces/mytree # start watching a workspace
nws list                         # see registered workspaces
nws unregister ~/workspaces/mytree
```

## How the generated root flake works

For each workspace, the daemon scans its **first-level subfolders** and treats
any containing `.git` or a `flake.nix` as a child repo. It then manages
`<workspace>/flake.nix` as a **user-owned flake with a managed nws block**:

- **No `flake.nix` yet** → nws creates a minimal one whose only content is
  the nws block.
- **`flake.nix` exists** → nws parses it and injects or updates **only its
  own marked block**, the region between these two lines:

```nix
# nws block — managed by nws; do not edit
# /nws block
```

  Everything outside the block is yours — `description`, `nixConfig`,
  formatting, comments, and the `};`/`}` that close the flake — and is
  byte-preserved across every regeneration.

A minimal example with two children, where `app` declares `lib` as a flake
input:

```nix
{
  description = "my workspace";   # ← user-owned, survives regeneration
# nws block — managed by nws; do not edit
  inputs = {
    app.url = "path:./app"; # nws: https://github.com/my-org/app.git
    # sibling wiring: app's own input `lib` resolves to the local checkout
    app.inputs.lib.url = "path:./lib";
    lib.url = "path:./lib"; # nws: https://github.com/my-org/lib.git
  };
  outputs = { self, ... }@inputs:
  let
    children = [ "app" "lib" ];
    # ... delegates packages/devShells/apps/checks per system ...
  in
  {
    packages  = delegate "packages";   # → packages.<sys>.<child>-<attr>
    devShells = delegate "devShells";
    apps      = delegate "apps";
    checks    = delegate "checks";
# /nws block
    devShells.x86_64-linux.ros = ...;   # ← your own outputs go below the END marker
  };
}
```

### The block: what nws owns, what you own

The nws block is **self-contained** — it declares the workspace's `inputs` and
the entire `outputs` expression (the `let … in { … }` with the generated
outputs) — and its `# /nws block` END line sits **inside** the outputs return
set. Concretely:

- nws **owns** everything above the END marker: inputs, sibling wiring, and
  the delegation/overlay machinery. That region is rewritten on every
  regeneration.
- You **own** everything below the END marker, still inside `outputs`: add
  your own output attributes (a `devShells.<system>.default`, extra
  `packages`, …) there. They survive regeneration verbatim, because nws only
  ever rewrites up to the END line.
- Nix rejects flake attributes outside `outputs` (a top-level
  `devShells = …` is an "unsupported attribute" error), which is precisely
  why the END marker lives inside the return set: anything you write below it
  is ordinary Nix.
- The two closing lines — the `};` of the return set and the flake's final
  `}` — belong to the file, not the block. Leave them in place (when nws
  injects a block into an existing flake it emits the `};` itself; when you
  write a block by hand, keep both closing lines below the END marker).

**Stable binding names (a contract):** your attributes may reference the
block's internals by these names, which never change between generations:
`spliced0`, `childCalls0`, `base0`, `overlay0`, `nixpkgs`, `inputs`. A
devShell written against one generation keeps working after the next.

### The rules

1. **Cloned child** → `inputs.<name>.url = "path:./<name>"`, with the clone's
   `origin` remote (read from `.git/config`, no subprocesses) recorded in a
   `# nws: <canonical-url>` marker comment.
2. **Removed clone** → the input is emitted at the canonical URL from
   `~/.config/nws/state.json` instead, so `nix build` keeps working against
   GitHub. State is written atomically and updated whenever a remote is
   observed.
3. **Sibling wiring** → when a child's own `flake.nix` declares an input whose
   name matches another workspace child, the generator emits
   `inputs.<child>.inputs.<dep>.url = "path:./<dep>"`. Dependency resolution
   is conservative (top-level entries of the child's `inputs` block only);
   anything it cannot confidently parse is left alone — fail-open, never
   corrupt the graph.
4. **Output delegation** → children's `packages`/`devShells`/`apps`/`checks`
   are re-exported per system as `packages.<sys>.<child>-<attr>`. The
   `<child>-` prefix makes `.default` collisions impossible by construction;
   the system set is the union across all children.
5. **Idempotency** → generation is a pure function of (sorted children +
   state). The daemon writes atomically (temp file + rename) and only when the
   bytes differ, so inotify self-triggers converge immediately.

### What nws will not do

- **Never modify a child repo.** Children are only read (`.git/config`, and
  their `flake.nix` for input-name parsing). Your checkouts stay pristine.
- **Never touch user content outside the block.** `description`, `nixConfig`,
  formatting, comments, and any attrs you write below the `# /nws block`
  line are preserved verbatim; regeneration rewrites only the marked block,
  atomically (temp file + rename) and only when the bytes differ. A flake
  that already declares its own top-level `inputs`/`outputs` (e.g. a devenv
  flake) is logged and left alone — injecting the block would duplicate
  those attributes and break evaluation.
- **Legacy v1 flakes.** A root flake written by an older nws (with a
  `# nws-generated — do not edit` header) declares its own top-level
  `inputs`/`outputs`, so nws logs a warning and leaves it alone — never
  corrupted, but no longer tracked. To migrate, delete the file (or remove
  its own `inputs`/`outputs`) and let nws regenerate a block-managed flake on
  the next scan, or insert the two marker lines yourself between your `{` and
  the closing `}` — keeping the `};` and `}` closing lines below the
  `# /nws block` line.
- **Never crash on odd input.** Unreadable git configs, worktree-style `.git`
  files, corrupt state — everything fails open (the child just keeps its
  GitHub URL or gets a plain `path:` pin without a marker).

### Migrating from the old per-child scheme

Earlier versions rewrote child flakes in place (inline `# nws:` markers
inside each repo). Those markers are now inert comments; the daemon no longer
touches child flakes at all. Remove the markers from your repos at your
leisure — nws now manages only its marked block in the workspace root.

### Workflow notes

Because children keep pointing at GitHub, **run Nix from the workspace
root** — that is where the local pins live. To build one child against its
own (GitHub) dependencies, build inside the child folder as usual, or use
`--override-input` against the root flake. Children with broken evaluation
will break the root flake's delegated outputs; that is inherent to
delegation.

## Configuration

The daemon reads `~/.config/nws/config.json` on startup, or the path given
with `--config-path`. If the file is missing or corrupt, the daemon falls
back to defaults instead of crashing.

```json
{
  "port": 17424,
  "workspaces": [
    "/home/you/workspaces/mytree"
  ]
}
```

- `port` — TCP control-socket port (`127.0.0.1:<port>`). Default `17424`.
- `workspaces` — canonical absolute workspace paths; duplicates rejected.

The file is written atomically; `register`/`unregister` update it
automatically. Watches are re-established from the config on startup, so
state survives reboots. The canonical-URL state lives next to it
(`~/.config/nws/state.json` by default) and is pruned automatically when you
unregister a workspace.

## Overlay workspaces

By default every workspace uses the flake-delegation backend described above.
A workspace can instead use the **overlay** backend: the generated root flake
imports a user-configured overlay flake (e.g.
[nix-ros-overlay](https://github.com/lopsided98/nix-ros-overlay)), applies it
over nixpkgs, and splices each child directory into the overlay's package set
at a configured attribute path — a `src` override when the overlay already
defines the child name, a source build (buildRosPackage/callPackage)
otherwise (see "Child discovery" below). Your modified
packages shadow the upstream ones; everything else comes from the overlay.
Sibling dependencies are resolved by the package-set fixed point (attribute
name shadowing), not by nws — removing a clone naturally falls back to the
upstream package.

### Registering an overlay workspace from the CLI

The easiest way is `nws register` with the overlay flags — no hand-editing of
`config.json` required:

```bash
# ROS 1 noetic overlay:
nws register /tmp/ws \
  --overlay github:lopsided98/nix-ros-overlay/ros1-25.05 \
  --attr-path rosPackages.noetic

# Same, with an external resolver script that maps package names to repo
# paths the built-in scan would not find (see "External resolver" below):
nws register /tmp/ws \
  --overlay github:lopsided98/nix-ros-overlay/ros1-25.05 \
  --attr-path rosPackages.noetic \
  --resolver /home/you/ros-ws/find_packages.sh

# Non-flake overlay with a named attribute and explicit nixpkgs:
nws register /tmp/ws2 \
  --overlay 'github:foo/bar' --attr-path pkgs --overlay-attr myOverlay \
  --no-flake --nixpkgs github:NixOS/nixpkgs/nixos-25.05
```

- `--overlay URL` may be repeated for multiple entries; each pairs with the
  following `--attr-path`. An `--overlay` without its `--attr-path` is a
  usage error, as is an `--attr-path`/`--overlay-attr`/`--no-flake` with no
  preceding `--overlay`.
- `--resolver SCRIPT` (optional, workspace-level) — a script the daemon runs
  once per sync to discover external packages that are not plain clones (see
  [External resolver](#external-resolver) below). Absent, only the built-in
  recursive scan is used.
- Presence of any `--overlay` selects the overlay backend; plain
  `nws register <path>` keeps the default flake backend.

Manual configuration remains possible with an object entry in `workspaces`
(legacy string entries keep the default flake backend):

```json
{
  "port": 17424,
  "workspaces": [
    {
      "name": "/home/you/ros-ws",
      "backend": "overlay",
      "overlays": [
        {
          "url": "github:lopsided98/nix-ros-overlay/master",
          "attrPath": "rosPackages.humble"
        }
      ]
    }
  ]
}
```

Per-overlay-entry fields:

- `url` (required) — the overlay flake URL.
- `attrPath` (required) — the package-set attribute path to extend, e.g.
  `rosPackages.humble`. The generated flake exposes this attribute with your
  children spliced in.
- `overlayAttr` (optional) — which overlay inside `overlays.<...>` to apply;
  defaults to `"default"`.
- `flake` (optional, default `true`) — set to `false` for a plain non-flake
  overlay expression; it is then imported via
  `import (builtins.fetchTarball "<url>")`.

Optional per-workspace fields:

- `resolver` — a script path for external package discovery, mirroring the
  `--resolver` CLI flag.
- `nixpkgs` — explicit nixpkgs URL for the root flake's input. When absent,
  the **nixpkgs cascade** applies (first match wins):
  1. workspace-level `nixpkgs` URL → `inputs.nixpkgs.url = <url>`;
  2. else the first flake overlay exposes nixpkgs →
     `inputs.nixpkgs.follows = "<overlay>/nixpkgs"`;
  3. else plain `import <nixpkgs>` (channel).

### Per-child user overrides: `.nws/packages/<attr-name>.nix`

Every spliced child in a generated overlay flake is guarded by a check on a
hidden, user-owned overrides folder:

```nix
<name> = prev:
  if builtins.pathExists ./.nws/packages/<name>.nix
  then prev.callPackage ./.nws/packages/<name>.nix { }
  else <bare source build (buildRosPackage / callPackage ./<child> { })>;
```

If `<workspace>/.nws/packages/<attr-name>.nix` exists, it is called with
`callPackage` **against the spliced package set**, so its arguments are its
dependencies — and any dependency whose attribute name matches another spliced
child resolves to your local sibling instead of the upstream package.
nws never creates this folder; it is purely opt-in, and absence is fine (the
`pathExists` guard simply falls through to the bare build).

Example for ROS 1, overriding `turtlebot3_msgs` while keeping its source in
the untouched clone:

```nix
# /path/to/workspace/.nws/packages/turtlebot3_msgs.nix
{ buildRosPackage, catkin, message_generation, message_runtime, rospy }:
buildRosPackage {
  pname = "turtlebot3_msgs";
  version = "1.0.1";
  src = ../turtlebot3_msgs;          # points back at the untouched clone
  buildType = "catkin";
  propagatedBuildInputs = [ message_generation message_runtime rospy ];
}
```

Note that `src` is relative to `.nws/packages/`, so it points back out at the
clone — which nws never modifies. Children without an override file fail open:
they keep the bare `buildRosPackage`/`callPackage` behaviour described above.
The daemon ignores `.nws` when scanning for child candidates (hidden
directories are never children), so only real repos are spliced.

### Child discovery: built-in recursive scan

Discovery is a built-in **recursive scan** of the workspace (always on),
unioned with an optional external **resolver** script (see below). The scan
recurses from the workspace root and emits one child per directory that owns
`flake.nix` **or any `.nix` file**, and never descends into such a directory
(the package boundary) — so nested workspace trees yield one package per
flow-folder. Hidden entries (leading `.`, e.g. `.git`, `.nws`) are never
children and are never descended into. Children are sorted by rel_path
(deterministic). Scanning is bounded by a depth cap (3 segments below root, so
`monorepo/pkg/foo` is the deepest recognized shape) and a count cap (200
children); hitting either logs a warning and stops at that boundary — it
never fails.

Each discovered child is spliced to replace the upstream package whose
**attribute name matches the child's basename**: when the name exists in the
overlay scope, the splice is a `src` override that inherits the package's
dependencies from the overlay rather than re-parsing them:

```nix
<name> = prev:
  if builtins.pathExists ./.nws/packages/<name>.nix
  then prev.callPackage ./.nws/packages/<name>.nix { }
  else if (prev.<name> or null) != null
  then prev.<name>.overrideAttrs (final: { src = ./<rel_path>; })
  else if (prev.buildRosPackage or null) != null
  then prev.buildRosPackage { pname="<name>"; version="0.0.0"; src=./<rel_path>; }
  else prev.callPackage ./<rel_path> { };
```

So for a plain clone of a package the overlay already defines, the clone
shadows the upstream source while dependency resolution comes straight from
the overlay. The `.nws/packages` override hook and the `buildRosPackage` /
bare `callPackage` fallbacks stay for raw checkouts that cannot be cloned.

Every spliced child is also collected into a `default` output
(`default = { <name> = spliced0.<name>; ... }`), so a bare `nix build` from
the workspace root builds the whole substitution set with no extra
arguments; `packages.<system>` re-exports the same set for `--attr` access.

### External resolver

For packages that a plain directory scan cannot recognise, a workspace can
point at a **resolver script** (`--resolver SCRIPT` / `resolver` config
field). Once per sync nws runs the script once with the workspace root as its
working directory and first argument, and parses its stdout. Each line's
`NAME<TAB>RELPATH` yields one spliced child (NAME = overlay attribute key,
RELPATH = path relative to the workspace root):

```bash
#!/usr/bin/env bash
# ROS example: emit `NAME<TAB>RELPATH` for every package.xml under the
# workspace root (RELPATH relative to the root, which is argv[1]).
root=$1
cd "$root" || exit 1
find . -name package.xml | while read -r f; do
  d=$(dirname "$f")
  name=$(awk -F'[<>]' '/<name>/{print $3; exit}' "$f")
  [ -n "$name" ] && printf '%s\t%s\n' "$name" "${d#./}"
done
```

Malformed lines (blank, no tab, empty NAME/RELPATH) are skipped fail-open; a
RELPATH that is not relative (absolute) aborts the whole parse; a non-zero
exit or spawn failure yields no children from the resolver, but never fails
the regeneration — the built-in scan's children and a minimal flake are still
emitted. When the same package name arrives from both producers at different
paths, the resolver wins (authoritative) and a warning is logged; the same
physical path from both is deduplicated. Everything runs on the daemon's
single thread (inline subprocess, no threads).

### Fail-open behaviour

Overlay mode never guesses. A broken resolver (bad script, network lookup
inside it fails, non-zero exit) degrades to the built-in scan's children and
a minimal managed flake — never to a flake that hard-breaks eval. A wrong
splice could break evaluation of the whole root flake, so a broken overlay
degrades to "no overrides", never to an unbuildable flake. Overlay children
need no `.git` and no `flake.nix`, and no canonical-URL state is kept for
them.

As always, a root `flake.nix` that nws cannot patch safely — unparseable, or
already declaring its own top-level `inputs`/`outputs` — is logged and left
untouched, and identical regenerations are skipped byte-for-byte.

## Shell completion

`nws` ships static tab-completion for **bash**, **zsh**, and **fish**, under
`share/` in the `main` derivation. Install into your profile for them to
activate:

```bash
nix profile install .#main
```

| shell | file | how it's picked up |
|-------|------|--------------------|
| bash  | `share/bash-completion/completions/nws` | needs the `bash-completion` package |
| zsh   | `share/zsh/site-functions/_nws` | needs `compinit` (standard on NixOS); if needed add `fpath+=(${^XDG_DATA_DIRS}/share/zsh/site-functions(N))` before `compinit` |
| fish  | `share/fish/vendor_completions.d/nws.fish` | auto-loaded |

What completes:

- `nws <TAB>` — subcommands `service register unregister list help`.
- `nws register <TAB>` — filesystem paths; `--<TAB>` offers the overlay flags
  (`--overlay`, `--attr-path`, `--overlay-attr`, `--no-flake`, `--nixpkgs`,
  `--resolver`).
- `nws unregister <TAB>` — registered workspace canonical paths, **only while
  the daemon is reachable**; falls back to plain filesystem completion
  otherwise (never hangs).

## Control wire protocol

Raw newline-delimited TCP on `127.0.0.1:<port>` — no HTTP. One request line
in, one reply line out (`OK`, `ERROR <msg>`, or `OK n` plus paths for
`LIST`). Paths are percent-encoded so spaces and `%` round-trip safely.

`REGISTER` optionally takes a query-string suffix carrying backend options:

```
REGISTER /home/you/ros-ws?backend=overlay&overlay=<pct(url)>&attrPath=<pct(attr)>
```

The path segment escapes space, `%`, `?`, `&`, and `=`, so the first `?`
unambiguously starts the query. Query keys: `backend=overlay`; repeatable
`overlay=`/`attrPath=` pairs (each overlay needs its attrPath); optional
`overlayAttr=` and `flake=false` applying to the latest overlay; and optional
workspace-level `nixpkgs=` and `resolver=`. A bare legacy
`REGISTER <pct(path)>` keeps the
default flake backend. Malformed requests (bad escapes, unsupported backend,
incomplete pairing) get an `ERROR` reply.

```
$ printf 'LIST\n' | nc 127.0.0.1 17424
OK 1
/home/you/workspaces/mytree
```

## Manual verification checklist

1. `nix build .#main && devenv test`.
2. Register an overlay workspace via the CLI:
   `result/bin/nws register /tmp/ros-ws --overlay github:lopsided98/nix-ros-overlay/master --attr-path rosPackages.humble`;
   confirm config.json now contains the overlay workspace object, the
   generated flake contains the nws block, follows the overlay's nixpkgs,
   and splices a sample package dir at the configured attrPath. Add a
   `devShells.<system>.default` below the `# /nws block` line, touch a child
   dir, and confirm the devShell survives the regeneration.
3. Register the same workspace with `--resolver /path/to/resolver.sh`; the
   resolver round-trips into config.json (`resolver` field) and the wire
   (`&resolver=` query param).
4. `git clone` a real ROS package into the workspace → the daemon regenerates
   the flake with a `src` override for it, and the same clone still builds
   against overlay-inherited dependencies (claim token: `overrideAttrs`
   dep-inheritance). Touch a file in a child dir → regenerates identically
   (byte-skip, no loop).
5. A resolver that exists but exits non-zero (or emits junk) → warning logged,
   the built-in scan's children still spliced, minimal flake still emitted
   (fail-open); daemon needs no `nix` binary on `PATH` at all for overlay
   discovery.
6. Bare `nix build` from the workspace root (no args) builds the substituted
   child set via the `default` output.
7. Delete a child dir → its attribute disappears and the upstream overlay
   package falls through.
8. Legacy string-array config loads and saves back byte-stable.

## Running the tests

```bash
devenv test
```

This runs `odin test tests -collection:nwscore=src` via the flake's
`enterTest` hook, plus the completion-script check and the `odinfmt` pre-commit
hook. Unit tests cover the root-flake generator (golden output, determinism,
sibling overrides, escaping), the inputs-block parser, git-remote parsing,
state round-trips, config handling, the overlay child scanner (clamp, depth
and count caps, hidden-dir skip), the resolver line parser, and the
builtin+resolver merge (rel_path dedup, resolver-wins), plus regenerated
overlay goldens and a `default`-output test.

After changes, also verify the build:

```bash
nix build .#main
```

Manual smoke test: `result/bin/nws service` in one shell, register a temp
workspace with two cloned repos, and check that the generated root flake wires
them locally while `git status` in both repos stays clean.

## Development workflow: `devenv up`

Inside the dev shell you can run the daemon directly as a devenv process:

```bash
devenv up
```

Stop with `Ctrl-C`.

## Layout

- `src/nix_workspace.odin` — the `package main` binary (CLI dispatch, daemon
  event loop, `sync_workspace`).
- `src/core/` — importable core logic (`package core`, imported as
  `nwscore:core`):
  - `root_flake.odin` — deterministic root-flake generator, inputs-block
    parser, block-boundary detection.
  - `flake_block.odin` — nws block region finder and flake patcher (the
    create/inject/update ownership boundary).
  - `git_remote.odin` — fail-open `.git/config` origin parser.
  - `state.odin` — atomic canonical-URL state (`state.json`).
  - `config.odin` — config load/save.
  - `scan_children.odin` — recursive overlay child scanner (flattening seam
    injected, pure).
  - `resolver.odin` — external resolver `NAME\tRELPATH` line parser and
    inline subprocess runner (fail-open).
  - `merge_children.odin` — union/dedup/sort of builtin scan + resolver.
  - `overlay_flake.odin` — overlay root-flake generator (src-override
    children, `default` output).
  - `register_wire.odin` — REGISTER query-wire encode/parse.
  - `url.odin` — percent encode/decode for the wire protocol.
- `tests/` — `package tests`; unit tests run by `odin test tests`.
- `completions/` — bash/zsh/fish completion sources.
- `flake.nix` — devenv flake: binary + systemd unit derivations, devenv
  process, dev shell, test hook.
