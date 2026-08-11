# Implementation Plan: `nws` — Nix Workspace Root Manager

**Date:** 2026-08-11 (rev. 2 after code review) · **Repo:** /home/alexfneves/gits/nws · **Language:** Odin (2026-07a)

## 1. What we're building

A single Odin CLI binary called `nws`. It has a long-running **daemon** mode and three **client** commands that talk to the daemon over a localhost TCP control socket.

- `nws service` — daemon. Reads `~/.config/nws/config.json` (a list of "workspace" folders + a TCP port), watches every workspace with **pure-Odin inotify**, and when a repo subfolder appears/disappears inside a workspace it rewrites that workspace's `flake.nix` so cloned repos are pinned to `path:./<name>` and uncloned ones keep (or return to) their GitHub URL. Also serves a tiny **TCP control socket** on `127.0.0.1:<port>`.
- `nws register [PATH]` (default `$PWD`) — asks the daemon to add a workspace → daemon appends to config.json and starts watching it.
- `nws unregister [PATH]` — daemon removes it from config.json and stops watching.
- `nws list` — daemon returns the current workspace list.
- `nws help` — usage.

Config persists across reboots, so the daemon re-establishes all watches on startup. Built by the Nix flake; also runs as a devenv process under `devenv up`.

> **Rev. 2 note:** this plan was adjusted after a code review. Each revised behaviour is marked with a **→** arrow. The full list of resolved gaps is consolidated in §9.

## 2. Key design decisions

**Why single-threaded poll-multiplexing (not threads):** Odin's `context.allocator` is per-thread, so sharing `[dynamic]` config/workspace state across the watcher and control-socket threads invites allocator bugs. Instead the whole daemon is **one event loop** using `linux.poll` over `[inotify_fd, listen_fd, ...client_fds]`. Allocations stay in one thread. This is also the "let the kernel do the watching" property the user wants — no busy loops.

**Raw TCP control protocol (no HTTP):** `core:net` has no HTTP server (no `core:net/http`, no `vendor/http` in this Odin), so per the user's instruction we use plain **TCP sockets** with a tiny line-delimited command protocol. The daemon listens on `127.0.0.1:<port>` via `core:net` (`listen_tcp`/`accept_tcp`/`recv_tcp`/`send_tcp`), casting `TCP_Socket` → `linux.Fd` for `poll`. The client sends one text line per request; the server replies with a single line — newline-terminated, no headers or content-length, since only our own CLI talks to it.

- → **Command grammar:** first token up to the first ASCII space is the verb (`REGISTER`/`UNREGISTER`/`LIST`); the remainder encodes a path. Replies: `OK\n`, `ERROR <msg>\n`, or `OK n\n<paths...>` for `LIST`.
- → **Path framing (spaces/% safety):** paths are **percent-encoded** on the wire (`%20`→space, `%25`→`%`, `/` kept as-is). The server splits verb on the first space, then URL-decodes the remainder before lookup. A tiny hand-rolled encode/decode helper is used (no external dep).
- → **Non-blocking sockets:** immediately after `listen_tcp` and after each `accept_tcp`, call `net.set_blocking(socket, false)` so both the listening socket and every accepted client are non-blocking before entering `poll()`. A blocking `recv_tcp` would stall the whole loop.
- → **Per-fd read buffering:** the server keeps a `[dynamic]u8` read buffer per client fd and appends every `recv` chunk; a command is dispatched only after a full `\n` is present (handles partial-line / multi-chunk arrivals). On EOF or a 0-byte read, the client is dropped and its fd + poll entries are removed (careful removal while iterating the dynamic poll array — swap-remove by index).

**Watch granularity:** one non-recursive inotify watch on each workspace *root*. We only care about (a) presence of first-level subfolders (a clone appears/disappears) and (b) edits to the workspace's own `flake.nix`. Non-recursive is correct and cheap.

- → **Watch mask:** to catch root-level flake edits we need `IN_CLOSE_WRITE` (fires after a write completes) in addition to `IN_CREATE`, `IN_DELETE`, `IN_MOVED_TO`, `IN_MOVED_FROM`, `IN_ATTRIB`. Do **not** set `IN_ONLYDIR` — the same watch also covers the `flake.nix` file, and `ONLYDIR` restricts to directory-only events.
- → **Variable-length event parsing:** `Inotify_Event { wd, mask, cookie, len, name: [0]u8 }` is variable-length. Parse the read buffer in a loop: at each offset read the fixed 16-byte header, then advance by `size_of(Inotify_Event) + event.len` using `event.len`. Never treat one `read()` as a single struct.
- → **Overflow & removal recovery:** on `IN_Q_OVERFLOW` force a full rescan by calling `sync_workspace(path)` for every live workspace. On `IN_IGNORED` (root deleted or watch removed) drop the stale `Workspace` entry and remove its wd. On `IN_DELETE_SELF`/`IN_MOVE_SELF` of a subfolder, re-sync so the flake reverts to canonical URLs.

**Flake override is reversible:** nws records the original (canonical) URL by writing a `# nws: <canonical>` marker comment on the line it manages. On deletion of a clone it restores that canonical URL. This keeps `config.json` minimal (path list only, per the user's "keep it minimal" constraint) because the canonical info lives in the flake itself.

## 3. Environment / API facts (verified against installed Odin)

All symbols verified present in `/nix/store/vhz63axfnij1wlfpsfxpcrzgd5rlnj99-odin-dev-2026-07a/share/core`.

- **inotify** (`core:sys/linux`, imported as `linux`):
  - `inotify_init1(flags: linux.Inotify_Init_Flags) -> (Fd, Errno)` — flags `.NONBLOCK, .CLOEXEC`
  - `inotify_add_watch(fd: Fd, pathname: cstring, mask: linux.Inotify_Event_Mask) -> (Wd, Errno)`
  - `inotify_rm_watch(fd: Fd, wd: Wd) -> Errno`
  - `read(fd: Fd, buf: []u8) -> (int, Errno)` and `poll(fds: []Poll_Fd, timeout: i32) -> (i32, Errno)`, `close(fd)`
  - `Inotify_Event :: struct { wd: Wd, mask: Inotify_Event_Mask, cookie: u32, len: u32, name: [0]u8 }` (size 16; name follows struct, length-prefixed by `len`)
  - `Inotify_Event_Mask :: bit_set[Inotify_Event_Bits; u32]` members: `.ACCESS .MODIFY .ATTRIB .CLOSE_WRITE .CLOSE_NOWRITE .OPEN .MOVED_FROM .MOVED_TO .CREATE .DELETE .DELETE_SELF .MOVE_SELF .UNMOUNT .Q_OVERFLOW .IGNORED .ONLYDIR .DONT_FOLLOW ...`
  - `Poll_Fd :: struct { fd, events, revents: Fd_Poll_Events }`; `Fd_Poll_Events` bits `.IN .PRI .OUT .ERR .HUP .NVAL ...`
- **sockets** (`core:net`):
  - `listen_tcp(interface_endpoint: net.Endpoint, backlog := 1000) -> (socket: TCP_Socket, err: net.Network_Error)`
  - `accept_tcp(socket: TCP_Socket, options := DEFAULT_TCP_OPTIONS) -> (client: TCP_Socket, source: net.Endpoint, err: net.Accept_Error)`
  - `recv_tcp(socket, buf: []byte) -> (int, net.TCP_Recv_Error)`, `send_tcp(socket, buf: []byte) -> (int, net.TCP_Send_Error)`
  - `close(socket: Any_Socket)`, `parse_endpoint(str) -> (Endpoint, bool)`, `set_blocking(socket, bool)`
  - `TCP_Socket :: distinct Socket`, `Socket :: distinct i64` → cast `linux.Fd(transmute(i64)sock)` for poll
  - → **FD-width check:** `linux.Fd` on this platform is a 32-bit int; the `transmute(i64)` source matches the i64 `Socket`, and the cast to `linux.Fd` truncates safely for real fds. Confirm with a compile-time assertion / quick `os.build_arch` check during wiring.
- **json** (`core:encoding/json`): `json.parse(data) -> (Value, Error)`; `Value :: union{Null,Integer,Float,Boolean,String,Array,Object}`; `Array :: distinct [dynamic]Value`; `Object :: distinct map[string]Value`.
- **os** (`core:os`): `os.read_entire_file(path, context.allocator) -> ([]byte, os.Error)`, `os.write_entire_file(path, data, perm, truncate) -> os.Error`, `os.exists(path) -> bool`, `os.is_dir(path)`, `os.make_directory(path, perm)`, `os.rename(old,new)`, `os.remove(name)`, `os.real_path(path)`, `os.user_home_dir(context.allocator) -> (string, os.Error)`, `os.get_env_buf`.

**devenv `processes` module** (verified in devenv source): `processes.<name>.exec` (a Bash string), `.restart`, `.env`, `.cwd`, `.start.enable`. `devenv up` runs these via process-compose.

## 4. Flake transformation rules (the core)

For a workspace folder `W`, run `sync_workspace(W)` on startup (for every loaded workspace) **and** on each relevant inotify event:

1. Read `W/flake.nix` as text (skip if missing).
2. Determine first-level subfolders of `W` that are "local repos": subfolder `D` where `W/D/.git` exists **or** `W/D/flake.nix` exists. Input name = `D`.
3. For each input line in the `inputs` block that matches a `NAME.url = "VALUE";` assignment (single identifier before `.url`, no nested dots):
   - If subfolder `NAME` is a local repo → set `url = "path:./NAME"`. The canonical URL is remembered as `VALUE` the first time (or from an existing `# nws: <canonical>` marker), and the line is rewritten as `NAME.url = "path:./NAME";  # nws: <canonical>`.
   - Else if the line already carries `# nws: <canonical>` (previously managed, clone now removed) → restore `url = "<canonical>"`, keeping the marker.
   - Else → leave untouched (e.g. `repo-b.url = "github:...";` that was never cloned).
   - → **Marker hygiene:** if the managed line already has a `# nws: <canonical>` marker (from a prior rewrite), **do not append a second marker** — reuse/update the existing one. Otherwise an idempotent rewrite that runs twice would produce duplicate `# nws:` markers.
4. If the rewritten text differs, atomically write it back (temp file in same dir + `os.rename`).
5. Leave `follows` lines and other input attributes alone (deferred; see §5).

Target output matches the user's example:
```nix
inputs = {
  repo-a.url = "path:./repo-a";            # nws: github:my-org/repo-a
  repo-b.url = "github:my-org/repo-b";
};
```

**Parsing discipline (guarding the line-based transform):**
- → Match assignments defensively: trim whitespace, require the `NAME.url =` shape with a single identifier before `.url`, and require `"VALUE"` (double-quoted) without stray characters. Preserve original indentation and any trailing text after the value.
- → Do not rewrite lines that are inside a multi-line string, a comment, or that reuse `.url` with nested attrs (e.g. `repo.url.foo`). If a line can't be parsed confidently, leave it untouched (fail-open, never corrupt the flake).
- → Recognise existing `# nws:` markers via a regex/contains check for `# nws:` and parse the canonical URL after it; re-emit it on restore.

## 5. Scope / explicit non-goals (v1)
- **No generic `follows` injection.** Needs per-workspace metadata that contradicts "keep it minimal". Left for a future config extension.
- **No `nws sync`/`nws ensure` commands.** Use `nws service`.
- **No auth** on the TCP control socket (localhost only, `127.0.0.1`).
- **No unit install automation** — the `.service` file is shipped with the binary; user copies it to `~/.config/systemd/user/` and enables it (documented).
- **No generic Nix parser.** The transform is line-based and intentionally conservative a §4; arbitrary/edge-case Nix files are copied through unchanged rather than attempted.

## 6. Files to change

### `src/nix_workspace.odin` (rewrite — the entire program)
- **Config:** `Config { port: int, workspaces: [dynamic]string }`; `config_path() = ~/.config/nws/config.json` (from `os.user_home_dir`); `load_config` (hand-parse with `json.parse`, defensive: missing keys → defaults, corrupted JSON → fall back to defaults), `save_config` (hand-write JSON string; ensure `~/.config/nws` exists with `os.make_directory(dirs=true)`; write atomically via temp file + `os.rename`). → `DEFAULT_PORT = 17424`. → Store canonical **absolute** paths (see register below).
- → **Path normalisation / dedup:** `REGISTER <PATH>` canonicalises with `os.real_path`, normalises to an absolute path, and rejects duplicates (already-registered → `ERROR already registered`). Only canonical absolute paths are stored in config and used for `inotify_add_watch`.
- **CLI dispatch:** `main()` parses `os.args` → service/register/unregister/list/help. Client commands read config for the port (fallback `DEFAULT_PORT`), then `net.dial_tcp` to `127.0.0.1:port`.
- **TCP client:** tiny `tcp_request(line) -> (ok, reply)` over `dial_tcp`; sends one percent-encoded command line, reads reply line(s); register/unregister send `REGISTER <urlencoded-path>` / `UNREGISTER <urlencoded-path>`, list sends `LIST` and parses the returned paths.
- **Daemon state:** package-level `Daemon_State { inotify_fd, listen_socket, workspaces: [dynamic]Workspace, client_bufs: map[linux.Fd][dynamic]u8, config }`; `Workspace { path, wd }`.
- **TCP server (poll-multiplexed):** maintain a dynamic poll-fd list + a per-fd read buffer; accumulate bytes until a `\n`, then split verb / URL-decode path and route: `REGISTER <path>` → `add_workspace`, `UNREGISTER <path>` → `remove_workspace`, `LIST` → return paths. Reply, then close (connection-per-request for simplicity).
- **Watcher loop:** `for { poll([...fds], -1); drain inotify; accept; service tcp; }` → route events by `wd` → `sync_workspace(path)`. On `IN_Q_OVERFLOW` rescan all; on `IN_IGNORED` drop entry.
- **Watcher mgmt:** `add_workspace(path)` / `remove_workspace(path)` — `inotify_add_watch` / `inotify_rm_watch`, update `workspaces` + config, persist. → **Call `sync_workspace(path)` immediately after adding a watch** (and on daemon startup for every loaded workspace) so an already-present clone is materialised right away, not just on the next inotify event. Handle `IN_IGNORED` (workspace root deleted) by dropping the entry.
- **Sync:** `sync_workspace(path)` implements §4; reads/writes `W/flake.nix` atomically.
- → **Logging:** daemon logs events to stderr (`DEBUG <std::time>`-style lines for watch add/remove, flake rewrites, and connection handling) — essential for debugging poll/inotify behaviour. Optional env `NWS_LOG=0` to silence.
- → **Unit tests for the flake rewrite:** add an Odin test in the `tests/` folder (`package tests`, e.g. `tests/flake_test.odin`) that feeds sample flake inputs (managed, unmanaged, marker-already-present, nested-attr, comment/space variants) and asserts the rewritten text. Run via `devenv test` (which executes `enterTest` = `odin test tests`).
- → **Config parser tests:** round-trip a sample config (incl. paths with spaces/URL-encoding) through `save_config`/`load_config`, in `tests/`.
- → **Importability:** any logic that must be unit-tested (flake transform, config, URL encode/decode) should be factored into an importable non-`main` package (e.g. `src/core`, wired via a collection), so `tests/` can import it while `src/nix_workspace.odin` stays as the thin `package main` binary. Keep `src/nix_workspace.odin` itself free of test procedures.

### `flake.nix`
- Keep `-file` build; keep odin-fmt git hook.
- → **Build & test entrypoints:** set up the devShell so agents use devenv's standard test entrypoint: `enterTest` runs the Odin unit tests. Building the binary is done via **`nix build`** (`devenv build` does not exist for a flake). Concretely:
  - Add `odin test tests -collection:nwscore=src` to `enterTest` (required — `odin test` must live here so `devenv test` actually runs it). Unit tests live in the `tests/` folder (`tests/*_test.odin`, `package tests`); `src/nix_workspace.odin` is the `package main` binary and is **not** the test target.
  - Build with `nix build .#main` (output `./result`), and run tests with `devenv test`.
- **Ship a user unit:** add a second derivation `systemdUnit` producing `share/systemd/user/nws.service`:
  ```
  [Unit]
  Description=Nix Workspace daemon
  [Service]
  Type=simple
  ExecStart=%h/.nix-profile/bin/nws service
  Restart=on-failure
  [Install]
  WantedBy=default.target
  ```
  Make `main` also copy this into `$out/share/systemd/user/` (so it ships "together with the executable"). `default = main`.
- **devenv `processes`:** add to the existing module:
  ```nix
  packages = [ self.packages.${system}.main ];
  processes.nws.exec = "exec ${self.packages.${system}.main}/bin/nws service";
  ```
  so `devenv up` launches the daemon.

### `README.md` (new)
Usage, install (`nix build .#main` → `./result` → `nix profile install` or `devenv up` dev workflow), systemd enable steps, devenv up, config format, the flake-marker mechanism, the percent-encoding note, and how to run the unit tests (`devenv test`, which runs `odin test tests -collection:nwscore=src`; tests live in `tests/`).

## 7. Manual verification checklist
1. `nix build .#main` produces a binary and `result/bin/nws help` prints usage (`nix build` outputs to `result`).
2. `nws service` starts; `printf 'LIST\n' | nc 127.0.0.1 17424` → an empty count line.
3. `nws register <tmpws>` adds to `list` and `config.json`; a pre-declared repo input in `<tmpws>/flake.nix` gets `path:` when the subfolder clone exists and reverts to GitHub when removed. → Verify that registering a workspace with a clone **already present** materialises it without waiting for an inotify event (initial-sync path).
4. Restart daemon → watches re-established from config (reboot persistence). → Verify config dir/state survive restart and that stale `IN_IGNORED` workspaces are dropped cleanly.
5. `devenv up` launches the daemon as a process.
6. → **Negative / edge tests:** (a) `nws register` a path containing a space → correct handling end-to-end; (b) `nws register` the same path twice → `ERROR already registered`; (c) register while daemon runs, then delete the workspace root → entry dropped, no crash; (d) corrupt `config.json` → daemon starts with defaults instead of crashing; (e) concurrent register/unregister bursts → no double-count or stale poll fds; (f) clone-in-progress burst → flake is not left half-written (atomic rename) and ends idempotent.
7. `devenv test` passes (runs `odin test tests` via `enterTest`) for the flake-rewrite + config-roundtrip unit tests in `tests/`.

## 8. Risks / edge cases
- **Odin API drift:** exact signatures verified above; expect minor compile fixes while wiring `core:net` to `linux.poll` (fd casting via `transmute`, width check §3).
- **TCP framing:** a single client request may arrive in multiple `recv_tcp` chunks; buffered per-fd until a `\n` (handled). Paths are percent-encoded so spaces/`%` round-trip (handled).
- **JSON hand-parsing:** keep config parse defensive (missing keys → defaults, corrupt → defaults) and atomic writes (handled).
- **Clone-in-progress bursts:** inotify fires many events; we sync once per workspace per poll-drain, and a second sync after a tile is harmless (idempotent rewrite + atomic rename avoids partial writes).
- **Watch removal** on root deletion: handle `IN_IGNORED` to drop stale entries (handled).
- **Poll array mutation while iterating:** removing a closed client fd must use swap-remove or mark-and-sweep to avoid stale entries (noted in §2).
- **inotify queue overflow / fd exhaustion:** on `IN_Q_OVERFLOW` full-rescan; large workspace counts could exhaust fds — document a reasonable cap or degrade gracefully (v1: log a warning).
- **flake transform fragility:** line-based + fail-open; unusual Nix formatting is passed through unchanged rather than corrupted (handled in §4).

## 9. Consolidated post-review fixes (rev. 2)
1. **Initial sync** — `sync_workspace` runs immediately after `add_workspace` and for every loaded workspace on daemon start.
2. **Path handling** — canonicalise (`os.real_path`), dedupe, reject duplicates; store absolute paths.
3. **Non-blocking sockets + per-fd buffering** — `set_blocking(false)` on listen + accepted clients; buffer until `\n`.
4. **TCP path encoding** — percent-encode paths to survive spaces/`%`.
5. **Watch mask** — add `IN_CLOSE_WRITE`, drop `IN_ONLYDIR`.
6. **Variable-length inotify parsing** — loop with `len`-based advance.
7. **Overflow/removal recovery** — `IN_Q_OVERFLOW` → full rescan; `IN_IGNORED`/`DELETE_SELF` cleanup.
8. **Marker hygiene** — never append a duplicate `# nws:` marker.
9. **Config safety** — atomic write, dir auto-create, corrupt-file fallback.
10. **Logging to stderr** — for poll/inotify debugging.
11. **flake.nix** — ship `systemdUnit` + `processes.nws` + README; wire `odin test` into `enterTest`; build via `nix build .#main` and test via `devenv test`.
12. **Unit tests** — flake-rewrite + config round-trip via `odin test` (run with `devenv test`).
13. **Expanded verification** — negative/edge cases in §7.
