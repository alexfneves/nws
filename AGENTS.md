# AGENTS.md — Guide for AI coding agents in this repo

Instructions for any agent (or human) working in the `nws` repository. Read this before making changes.

## What this is

`nws` is a single Odin CLI binary that, in daemon mode (`nws service`), watches a set of Nix **workspace** folders and manages a generated `flake.nix` at each workspace root: cloned child repos are pinned via `path:./<name>` inputs (canonical GitHub URLs kept as `# nws:` markers and persisted in state), uncloned ones fall back to their GitHub URL, and the children's outputs are aggregated namespaced. Child flakes themselves are never modified. It also serves a per-user Unix domain control socket (default `$XDG_RUNTIME_DIR/nws/control.sock`) that the `register` / `unregister` / `list` client commands talk to.

See the current implementation plan (when present) under `.pi/plans/YYYY-MM-DD-<name>/plan.md`.

## Build and test — use devenv for the shell/test, nix build for the binary

This project is a devenv flake. Test/dev work uses devenv; **building the binary uses `nix build`** (`devenv build` does not exist):

```bash
nix build .#main   # build the binary; output symlink is ./result
nix build .        # same (default = main)
devenv test        # run tests (executes the `enterTest` hook)
devenv up          # run the dev processes (launches the daemon via processes.nws)
devenv shell       # enter the dev shell
```

- **Build:** run `nix build .#main` (or `nix build .`) — do **not** use `devenv build`. The flake's `installPhase` uses `odin build src/nix_workspace.odin -file -collection:nwscore=src -out:build/nws`; the output lands in `./result/bin/nws`.
- **Test:** run `devenv test`. This runs whatever is in the `enterTest` block of `flake.nix`, which must be the Odin test command:
  ```nix
  enterTest = ''
    odin test tests -collection:nwscore=src
  '';
  ```
  **Unit tests live in the `tests/` folder** (`tests/*_test.odin`, `package tests`). `src/nix_workspace.odin` is the `package main` binary and is **not** the test target — do not put test procedures there. `odin test tests -collection:nwscore=src` compiles the `tests/` package and runs its `@(test)` procedures. If you change the command in `flake.nix`, keep it pointing at `tests/`.

  **Importable core package (validated wiring):** testable logic lives in `src/core/` (`package core`). It is wired via the `nwscore` collection rooted at `src`, so **both** the build and test commands must carry `-collection:nwscore=src`, and code imports it as `import "nwscore:core"` (referencing symbols as `core.xxx`). The standard-library `core:` collection is separate and does not collide (e.g. `import "core:fmt"` is referenced as `fmt.xxx`).
- **Manual daemon smoke test:** `nix build .#main`, then `result/bin/nws service` in one shell, and `printf 'LIST\n' | nc -U "$XDG_RUNTIME_DIR/nws/control.sock"` in another. The scripted version is `tests/smoke_unix_socket.sh`; run it with `HOME` and `XDG_RUNTIME_DIR` pointing under `/tmp/nws-*` (it refuses otherwise) so the live config and socket are never touched.

## Repo layout

- `src/nix_workspace.odin` — the main `package main` binary (CLI dispatch, daemon top-level loop). `package main`.
- `src/core/` (planned) — importable, non-`main` core package holding the logic that needs unit tests: flake transform, config parse/save, URL encode/decode.
- `tests/` — `package tests`; unit tests for the core logic, run by `odin test tests`.
- `flake.nix` — devenv flake: binary derivation, systemd unit, `processes.nws`, devShell (enterShell/enterTest, odin-fmt pre-commit hook).
- `README.md` — usage docs.
- `.pi/plans/.../plan.md` — the active implementation plan.

## Code conventions

- Odin (2026-07a). Single-threaded event loop on purpose — Odin's allocator is per-thread, so keep all `[dynamic]` config/workspace state on one thread and multiplex with `linux.poll` (inotify fd + control-socket fds). **Do not** introduce threads for the daemon.
- No `core:net` / HTTP — the control protocol is raw newline-delimited text over a Unix stream socket, built on `core:sys/linux` (`socket`/`bind`/`accept`/`recv`/`send`). Path resolution lives in `src/core/control_socket.odin`, shared by daemon and CLI. Client paths are percent-encoded so spaces/`%` survive the wire.
- Control-socket security is load-bearing (REGISTER can name a resolver the daemon executes): keep the 0700 parent dir check, the 0600 socket mode and the `SO_PEERCRED` uid check before any request byte is read. Send with `MSG_NOSIGNAL`.
- Sockets must be non-blocking (`SOCK_NONBLOCK` on socket/accept) before they go into `poll()`; buffer client reads per-fd until a `\n`.
- inotify events are variable-length: parse the read buffer in a loop advancing by `size_of(Inotify_Event) + len`.
- The root flake is user-owned; nws injects/updates ONLY its marked
  `# nws block — managed by nws; do not edit` … `# /nws block` region (the
  END marker sits inside the outputs return set, so user output attrs —
  devShells — written below it persist across regenerations). Regeneration is
  deterministic and atomic (tmp+rename); writing identical bytes is skipped;
  flakes that are unparseable or already declare their own top-level
  `inputs`/`outputs` are left alone (fail-open).
- Child flakes are off-limits: nws never reads or writes them. Canonical URLs come from `<child>/.git/config` (`[remote "origin"]`) while cloned, else from `~/.config/nws/state.json`. Old inline `# nws:` markers in child flakes from the previous scheme are inert comments.
- Formatting: use `odinfmt`; the repo has a pre-commit `odin-fmt` git hook. Run `nix develop --command odinfmt src/nix_workspace.odin` if needed.
- Config lives at `~/.config/nws/config.json`; write it atomically (temp file + rename).

## Process / workflow notes (for agents)

- If a plan exists, follow it and read it fully before editing.
- For planning sessions, use the plan skill's artifacts (scout context → plan → todos) under `.pi/plans/`.
- Make one logical change per commit with a clear message (see the commit skill if available).
- After a change, run `nix build .#main` and `devenv test` to confirm nothing broke, and update the manual verification checklist if your change affects behaviour.
- If you extend `flake.nix`, always run `devenv test` to confirm the `enterTest` hook still works, since that is the only place tests are wired in.
