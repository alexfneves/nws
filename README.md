# nws — Nix Workspace Root Manager

`nws` is a single Odin CLI binary that keeps Nix workspace folders in sync with
the state of the repos cloned inside them.

A **daemon** (`nws service`) watches a set of Nix workspace folders and manages a
generated **root `flake.nix`** at the top of each workspace so that:

- every first-level subdirectory is declared as an input. A subfolder that is
  currently **cloned** (has its own `.git`) is pinned to `path:./<name>`, and
- a subfolder whose clone was **removed** falls back to the canonical GitHub URL
  recorded for it.

The daemon **never modifies the child repos' own flakes** — only the generated
root flake at the workspace root.

Repos are watched via pure-Odin inotify (no busy loops), and a tiny TCP control
socket lets the `register` / `unregister` / `list` client commands talk to the
running daemon.

## Build & install

Build the binary from the flake:

```bash
nix build .#main      # or just: nix build .
# output symlink: ./result  →  ./result/bin/nws
```

Install it into your Nix profile:

```bash
nix profile install ./result
# or, directly from the flake:
nix profile install .#main
```

Install the systemd **user** unit so the daemon starts on login:

```bash
mkdir -p ~/.config/systemd/user
cp ./result/share/systemd/user/nws.service ~/.config/systemd/user/nws.service
systemctl --user daemon-reload
systemctl --user enable --now nws

# check it is running:
systemctl --user status nws
```

The unit runs `%h/.nix-profile/bin/nws service` and restarts on failure
(`Restart=on-failure`). Both `nix build .#main` and `nix build .#systemdUnit`
produce the unit under `share/systemd/user/nws.service` — `main` ships it
together with the executable.

> The service assumes `nws` is installed into your user Nix profile as
> `~/.nix-profile/bin/nws`. If you install it somewhere else, edit the
> `ExecStart` line to point at the right binary.

## Development workflow: `devenv up`

This repository is also a devenv flake. Inside the dev shell you can launch the
daemon directly as a devenv process instead of via systemd:

```bash
devenv up
```

`devenv up` starts `nws service` through the `processes.nws` definition in
`flake.nix`. Stop it with `Ctrl-C` when you are done.

## CLI usage

```
nws service [--config-path PATH]  run the daemon (watches workspaces, serves the control socket)
nws register [PATH]     add a workspace (default: current directory)
nws unregister [PATH]   remove a workspace
nws list                list registered workspaces
nws help                show this help
```

`register` / `unregister` / `list` are client commands: they connect to the
daemon's control socket and ask the daemon to do the work, so the daemon must be
running first. Daemon logs (watch add/remove, root-flake regeneration, connection
handling) go to stderr; set `NWS_LOG=0` to silence them.

```bash
nws service [--config-path PATH] &  # start the daemon with optional config file
nws service &                    # start the daemon with default config
nws register ~/projects/mytree   # start watching a workspace
nws list                         # see registered workspaces
nws unregister ~/projects/mytree # stop watching it
```

## Shell completion

`nws` ships static tab-completion files for **bash**, **zsh**, and **fish**.
They are included in `main`'s `share/` tree, so you must install `nws` into
your Nix profile for them to be active:

```bash
nix profile install .#main
```

This is **required** for completion to work — a bare `nix develop` exposes the
files via `$XDG_DATA_DIRS`, but only *bash* scans that automatically; zsh and
fish need the files in their own completion search paths, and the profile
install places them there (`~/.nix-profile/share/...`).

| shell | file | how it's picked up |
|-------|------|--------------------|
| bash  | `share/bash-completion/completions/nws` | needs the `bash-completion` package (present on NixOS and in this devenv) |
| zsh   | `share/zsh/site-functions/_nws` | needs `autoload -Uz compinit && compinit` (standard on NixOS/home-manager). If it still doesn't complete in a `nix develop` shell, add the Nix completion dirs to `fpath` in your `~/.zshrc`: `fpath+=(${^XDG_DATA_DIRS}/share/zsh/site-functions(N))` before `compinit` |
| fish  | `share/fish/vendor_completions.d/nws.fish` | auto-loaded — nothing to enable |

What completes:

- `nws <TAB>` — the subcommands `service register unregister list help`.
- `nws register <TAB>` — filesystem paths (always).
- `nws unregister <TAB>` — the registered workspace canonical paths (from
  `nws list`), but **only while the daemon is reachable**. If the daemon is
  down it falls back to plain filesystem completion, so completion never
  hangs or errors.

## Configuration

The daemon reads `~/.config/nws/config.json` on startup, or the path given with `--config-path`. If the file is missing
or corrupt, the daemon falls back to defaults instead of crashing.

```json
{
  "port": 17424,
  "workspaces": [
    "/home/you/projects/mytree"
  ]
}
```

- `port` — the TCP control-socket port the daemon listens on
  (`127.0.0.1:<port>`). Defaults to `17424`.
- `workspaces` — the list of workspace folders to watch. Paths are canonical
  absolute paths and duplicates are rejected.

The file is written atomically (temp file + rename), the parent directory is
created on demand, and `register`/`unregister` update it automatically. The
daemon re-establishes all watches from the config on startup, so state survives
reboots.

## How the root flake works

For each workspace `W`, the daemon generates and manages a single
`W/flake.nix`, starting with the header:

```
# nws-generated — do not edit
```

### What the generated flake looks like

Each first-level subdirectory becomes one input, plus an outputs section that
aggregates the children's `packages`, `devShells`, `apps` and `checks` under
namespaced `<child>-` prefixed names (so `.default` collisions are impossible
by construction):

```nix
# nws-generated — do not edit
{
  inputs = {
    repo-a.url = "path:./repo-a"; # nws: github:my-org/repo-a
    repo-b.url = "github:my-org/repo-b";
  };
  # outputs delegate each child's packages/devShells/apps/checks
  # under <child>-<attr> names ...
}
```

- Cloned children get `path:./<name>` inputs; the original canonical URL is
  kept in the `# nws: <url>` comment on the same line (emitted exactly once,
  since the flake is regenerated from scratch rather than edited in place).
- Children whose clone is absent fall back to their canonical GitHub URL.
- A child with no discoverable canonical URL simply stays `path:`-pinned with
  no marker (fail-open).
- Children are always emitted in sorted order, so regeneration is
  byte-idempotent; writing identical bytes is skipped (no self-trigger loop).
  Writes are atomic (temp file + rename).

### Where the canonical URL comes from

While a child is cloned, its canonical URL is read from its own
`.git/config` (`[remote "origin"] url = ...`). Every URL observed this way is
persisted to `~/.config/nws/state.json` (or `state.json` in the directory of
the `--config-path` file), keyed by workspace path and repo name. When a clone
is later removed, the persisted URL is used, so the input restores to the
GitHub URL instead of dangling on a missing path.

### Behavior notes

- **User-authored root flakes are never touched.** If `W/flake.nix` exists but
  does not start with the `# nws-generated` header, nws logs and leaves it
  alone.
- **Deleting the generated root flake is safe:** it is regenerated on the next
  watch event. Likewise any edit to a managed root flake is overwritten on the
  next event — hence the *do not edit* warning.
- **Child repos keep their own flakes pristine**, still pointing at GitHub.
  Workflows therefore move to the workspace root: run `nix build` /
  `nix develop` there, or use
  `nix develop --override-input <child> ./<child>` when you want to work
  against a single child directly.

### Migration from the old scheme

Older nws versions rewrote child flakes in place and left inline
`# nws: ...` markers behind. Those markers are now **inert comments**; nws no
longer reads or writes child flakes, and you can delete the stale markers at
your leisure.

## Control wire protocol

The control socket is raw newline-delimited TCP on `127.0.0.1:<port>` (there is
no HTTP). The client sends one line per request; the server replies with a
single line (`OK`, `ERROR <msg>`, or `OK n` followed by the paths for `LIST`).

Paths are **percent-encoded** on the wire, so spaces and `%` characters in
workspace paths round-trip safely.

## Running the tests

Tests are Odin unit tests in `tests/` (root-flake generation, state and git
remote resolution, config round-trip), run through the devenv test entrypoint:

```bash
devenv test
```

This runs `odin test tests -collection:nwscore=src` via the flake's
`enterTest` hook. The importable core logic lives in `src/core/` (wired through
the `nwscore` collection) so it can be unit-tested without pulling in the
`package main` binary.

## Layout

- `src/nix_workspace.odin` — the `package main` binary (CLI dispatch, daemon
  event loop).
- `src/core/` — importable core logic: root-flake generator, git remote
  parsing, persisted state, config parse/save, URL encode/decode.
- `tests/` — unit tests for the core logic.
- `flake.nix` — devenv flake: binary + systemd unit derivations, devenv
  process, dev shell and test hook.
