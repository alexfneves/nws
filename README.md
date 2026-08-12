# nws — Nix Workspace Root Manager

`nws` is a single Odin CLI binary that keeps Nix workspace folders in sync with
the state of the repos cloned inside them.

A **daemon** (`nws service`) watches a set of Nix workspace folders and rewrites
each one's `flake.nix` so that:

- a repo subfolder that is currently **cloned** (has a `.git` or its own
  `flake.nix`) is pinned to `path:./<name>`, and
- a repo subfolder that is **not** cloned keeps (or returns to) its original
  GitHub URL.

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
nws service             run the daemon (watches workspaces, serves the control socket)
nws register [PATH]     add a workspace (default: current directory)
nws unregister [PATH]   remove a workspace
nws list                list registered workspaces
nws help                show this help
```

`register` / `unregister` / `list` are client commands: they connect to the
daemon's control socket and ask the daemon to do the work, so the daemon must be
running first. Daemon logs (watch add/remove, flake rewrites, connection
handling) go to stderr; set `NWS_LOG=0` to silence them.

```bash
nws service &                    # start the daemon
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

The daemon reads `~/.config/nws/config.json` on startup. If the file is missing
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

## How the flake rewrite works

For each workspace `W`, `nws` reads `W/flake.nix` and inspects each input line of
the form `NAME.url = "VALUE";`:

1. If subfolder `NAME` inside `W` is a **local repo** (has `.git` or
   `flake.nix`), the line is rewritten to `path:./NAME`. The original GitHub URL
   is remembered by writing a marker comment:

   ```nix
   inputs = {
     repo-a.url = "path:./repo-a";   # nws: github:my-org/repo-a
     repo-b.url = "github:my-org/repo-b";
   };
   ```

2. If the subfolder's clone is later **removed**, the line is restored to the
   canonical URL recorded in the `# nws: <canonical>` marker.

The marker is never duplicated on repeated rewrites. The transform is
deliberately **conservative and fail-open**: lines it cannot confidently parse
(multi-line strings, comments, nested `.url.foo` attributes, unusual formatting)
are passed through unchanged rather than risk corrupting the flake. Writes are
atomic, so a clone-in-progress burst never leaves a half-written file and the
result is idempotent.

The canonical URL lives in the flake itself, which is what keeps
`config.json` minimal (just a path list).

## Control wire protocol

The control socket is raw newline-delimited TCP on `127.0.0.1:<port>` (there is
no HTTP). The client sends one line per request; the server replies with a
single line (`OK`, `ERROR <msg>`, or `OK n` followed by the paths for `LIST`).

Paths are **percent-encoded** on the wire, so spaces and `%` characters in
workspace paths round-trip safely.

## Running the tests

Tests are Odin unit tests in `tests/` (flake-rewrite and config round-trip),
run through the devenv test entrypoint:

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
- `src/core/` — importable core logic: flake transform, config parse/save,
  URL encode/decode.
- `tests/` — unit tests for the core logic.
- `flake.nix` — devenv flake: binary + systemd unit derivations, devenv
  process, dev shell and test hook.
