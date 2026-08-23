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
nws unregister [PATH]   remove a workspace
nws list                list registered workspaces
nws help                show this help
```

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
any containing `.git` or a `flake.nix` as a child repo. It then generates
`<workspace>/flake.nix`, which always starts with the header:

```nix
# nws-generated — do not edit
```

A minimal example with two children, where `app` declares `lib` as a flake
input:

```nix
# nws-generated — do not edit
{
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
  };
}
```

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
- **Never touch a user-authored root flake.** If `<workspace>/flake.nix`
  exists without the `# nws-generated` header, the daemon logs and skips it.
  Delete the generated file and the next event recreates it.
- **Never crash on odd input.** Unreadable git configs, worktree-style `.git`
  files, corrupt state — everything fails open (the child just keeps its
  GitHub URL or gets a plain `path:` pin without a marker).

### Migrating from the old per-child scheme

Earlier versions rewrote child flakes in place (inline `# nws:` markers
inside each repo). Those markers are now inert comments; the daemon no longer
touches child flakes at all. Remove the markers from your repos at your
leisure, and let the daemon own the workspace root instead.

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
via `callPackage ./<child> {}` at a configured attribute path. Your modified
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

# Non-flake overlay with a named attribute and explicit nixpkgs:
nws register /tmp/ws2 \
  --overlay 'github:foo/bar' --attr-path pkgs --overlay-attr myOverlay \
  --no-flake --nixpkgs github:NixOS/nixpkgs/nixos-25.05
```

- `--overlay URL` may be repeated for multiple entries; each pairs with the
  following `--attr-path`. An `--overlay` without its `--attr-path` is a
  usage error, as is an `--attr-path`/`--overlay-attr`/`--no-flake` with no
  preceding `--overlay`.
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

Optional per-workspace field:

- `nixpkgs` — explicit nixpkgs URL for the root flake's input. When absent,
  the **nixpkgs cascade** applies (first match wins):
  1. workspace-level `nixpkgs` URL → `inputs.nixpkgs.url = <url>`;
  2. else the first flake overlay exposes nixpkgs →
     `inputs.nixpkgs.follows = "<overlay>/nixpkgs"`;
  3. else plain `import <nixpkgs>` (channel).

### Child matching

Candidates are every first-level directory of the workspace plus each one's
immediate subdirectories (so monorepo layouts work). Once per sync nws runs
`nix eval --json <url>#<attrPath> --apply 'builtins.attrNames'` and splices
exactly the candidates whose **basename** is an attribute of that set;
**deepest match wins**, so if both a repo root and a subdirectory match, only
the subdirectory is spliced. Attribute-name sets are cached in memory per
`(url, attrPath)`.

### Fail-open behaviour

Overlay mode never guesses. If `nix eval` fails (no network, nix missing,
corrupt output), nws logs a warning and keeps the last known attribute set;
if there has never been a successful evaluation, nothing is spliced and the
minimal managed flake is emitted instead. A wrong splice could break
evaluation of the whole root flake, so a broken overlay degrades to "no
overrides", never to an unbuildable flake. Overlay children need no `.git`
and no `flake.nix`, and no canonical-URL state is kept for them.

As always, a root `flake.nix` without the `# nws-generated — do not edit`
header is user-authored and never touched, and identical regenerations are
skipped byte-for-byte.

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
  (`--overlay`, `--attr-path`, `--overlay-attr`, `--no-flake`, `--nixpkgs`).
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
workspace-level `nixpkgs=`. A bare legacy `REGISTER <pct(path)>` keeps the
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
   generated flake has the managed header, follows the overlay's nixpkgs,
   and splices a sample package dir at the configured attrPath.
3. Touch a file in a child dir → regenerates identically (byte-skip, no loop).
4. Delete a child dir → its attribute disappears and the upstream overlay
   package falls through.
5. Start the daemon without `nix` on `PATH` → a warning is logged and the
   empty-splice minimal flake is emitted.
6. Legacy string-array config loads and saves back byte-stable.

## Running the tests

```bash
devenv test
```

This runs `odin test tests -collection:nwscore=src` via the flake's
`enterTest` hook, plus the completion-script check and the `odinfmt` pre-commit
hook. Unit tests cover the root-flake generator (golden output, determinism,
sibling overrides, escaping), the inputs-block parser, git-remote parsing,
state round-trips, and config handling.

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
    parser, managed-header detection.
  - `git_remote.odin` — fail-open `.git/config` origin parser.
  - `state.odin` — atomic canonical-URL state (`state.json`).
  - `config.odin` — config load/save.
  - `url.odin` — percent encode/decode for the wire protocol.
- `tests/` — `package tests`; unit tests run by `odin test tests`.
- `completions/` — bash/zsh/fish completion sources.
- `flake.nix` — devenv flake: binary + systemd unit derivations, devenv
  process, dev shell, test hook.
