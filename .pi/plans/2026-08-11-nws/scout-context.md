# Context for: implementing `nws` — Nix Workspace Root Manager (plan rev. 2)

## Current Repo State (verified)
- Repo: `/home/alexfneves/gits/nws`, a **devenv flake**. Odin is the only real project language; there is no `go.mod`/`Cargo`/etc.
- `src/nix_workspace.odin` — currently a **Hello World `package main`** (prints "Hello, World!"). This is the ONLY source file; nothing is implemented yet.
- `tests/` — **DOES NOT exist yet** (confirmed: `ls tests/` → no such directory). Worker must create it.
- `src/core/` — **DOES NOT exist yet** (confirmed). Planned importable non-`main` core package.
- `README.md` — **does not exist** (not present in `ls`). Must be created.
- `AGENTS.md` — just added; contains the authoritative build/test conventions (must be followed).
- Build artifacts present: `.devenv/`, `.direnv/` populated; `result -> /nix/store/k16vylmylchbk8fprallmmx9ly9nipbj-main` (a prior Hello-World build); `.pre-commit-config.yaml` symlink to a nix store JSON; `flake.lock` present.

## Build & Test entrypoints (from flake.nix / AGENTS.md)
- **Build:** `devenv build` (NOT raw `nix build .#main`). The flake's `packages.x86_64-linux.main` is `stdenv.mkDerivation` whose `installPhase` runs:
  ```sh
  mkdir -p $out/bin
  mkdir -p build
  odin build src/nix_workspace.odin -file -out:build/nws
  cp build/nws $out/bin/
  ```
  `buildInputs = [ pkgs.odin ]`. `default = main`. Output symlink lands at `./result`.
- **Test:** `devenv test` executes the devShell `enterTest` hook, currently:
  ```nix
  enterTest = ''
    odin test tests
  '';
  ```
  `odin test tests` compiles the `tests/` package and runs its `@(test)` procedures. `src/nix_workspace.odin` is `package main` and is NOT a test target.
- **shell:** `devenv shell`; `enterShell` currently just echoes a banner string. Also `devenv up` for dev processes (`processes.nws` — NOT yet present in flake.nix; must be added).
- **pre-commit hook:** `git-hooks.hooks.odin-fmt` is enabled. Entry uses `${pkgs.ols}/bin/odinfmt -stdin`, applies to `\.odin$` files, rewrites in place (via temp file). So committed Odin code must be `odinfmt`-clean; run `nix develop --command odinfmt <file>` if needed. (The OLS package provides the `odinfmt` binary.)

## Odin environment facts
- **Version:** `odin version` → `dev-2026-07`; binary at `/nix/store/vhz63axfnij1wlfpsfxpcrzgd5rlnj99-odin-dev-2026-07a/bin/odin`. Matches the plan's "2026-07a".
- `core:net`, `core:os`, `core:encoding/json`, `core:sys/linux` (inotify) all present under `share/core`. No `core:net/http` (plan relies on raw TCP).
- **`-file` flag confirmed:** `odin build filename.odin -file` builds a single file as a self-contained package that must contain an entry point. Both `odin build` and `odin test` support `-collection:<name>=<filepath>`.

## ⚠️ Importable-package wiring (the key gotcha)
The plan wants testable logic factored into an importable non-`main` package (e.g. `src/core`), wired **via a collection**, so that BOTH the `package main` binary and the `tests/` package can `import` it. Odin has no relative-path imports — a sibling directory is only importable through a named collection.

Consequences for the worker:
1. **`src/nix_workspace.odin` must `import "nwscore:..."` (or the chosen collection name)** to use the core logic. Import syntax for a custom collection: `import "mycol"` if the collection root is the package dir itself, or `import "mycol:subpkg"` if the collection root is a parent of the package (`src/core` with collection pointing at `src` → `import "nwscore:core"`).
2. **The flake `installPhase` currently has NO `-collection` flag.** `odin build src/nix_workspace.odin -file -out:build/nws` will FAIL the moment `nix_workspace.odin` imports the core package. Worker MUST add e.g. `-collection:nwscore=src/core` (exact name/root = worker's choice, be consistent) to the `installPhase` command.
3. **`enterTest` is currently bare `odin test tests`.** As soon as `tests/*_test.odin` (package tests) imports the core package, this will FAIL too. Worker MUST add the same `-collection:...` flag here. This is a plan/AGENTS consideration: AGENTS.md documents `enterTest = "odin test tests"` verbatim, so if the worker changes it to add a collection flag they should keep it pointing at `tests/` (AGENTS.md requires that).
4. Choose ONE collection name and use it identically in `installPhase`, `enterTest`, and the `import` statements. E.g. `-collection:nwscore=src/core` + `import "nwscore"` (if `src/core` is the collection root).

## Planned structure (from plan rev. 2)
- `src/nix_workspace.odin` — rewritten as the full `package main` binary (CLI dispatch, daemon poll loop, config load/save, TCP client/server, watcher mgmt). Free of `@(test)` procedures.
- `src/core/` (new) — importable non-`main` package: flake transform, config parse/save, URL encode/decode. This is what `tests/` imports.
- `tests/` (new, `package tests`) — `flake_test.odin` (flake rewrite: managed/unmanaged/marker-already-present/nested-attr/comment+space variants), config round-trip test (spaces/URL-encoding). Run via `devenv test`.
- `flake.nix` — keep `-file`, keep odin-fmt hook; add `-collection` wiring (mandatory, see above); add `systemdUnit` derivation shipping `share/systemd/user/nws.service`; have `main` copy the unit into `$out/share/systemd/user/`; add `packages = [ self.packages.${system}.main ]` and `processes.nws.exec = "exec ${...}/bin/nws service"` to the devenv module.
- `README.md` (new) — usage/install/systemd/devenv-up/config/marker/percent-encoding/unit-test instructions.

## Conventions (from AGENTS.md + plan)
- Odin (2026-07a). **Single-threaded** event loop, deliberately — all `[dynamic]` config/workspace state on one thread, multiplex via `linux.poll` (inotify fd + control-socket fds). **No threads in the daemon.**
- No `core:net/http`; raw newline-delimited TCP on `127.0.0.1:<port>` (default `17424`). Client paths percent-encoded on the wire.
- Sockets non-blocking (`net.set_blocking(sock, false)`) before going into `poll()`; buffer client reads per-fd until `\n`.
- inotify events variable-length — parse read buffer in a loop advancing by `size_of(Inotify_Event) + len`.
- `# nws: <canonical>` marker must never be duplicated; transform conservative/fail-open (never corrupt flake).
- Config at `~/.config/nws/config.json`; write atomically (temp file + rename). Store canonical absolute paths, dedupe, reject duplicates.
- One logical change per commit; after changes run `devenv build` + `devenv test`; if flake.nix changes, re-run `devenv test` (only place tests are wired).
- Format Odin with `odinfmt` (pre-commit hook enforces it).

## .gitignore
Covers: `.devenv/`, `.direnv/`, `result`, `build/`, `*.tmp`, `*.out`, `*.o`, `*.a`, `*.so`, `*.swp`, `*~`, `.DS_Store`, `*.log`. Note `result` and `build/` are ignored — the binary + build dir won't pollute git.

## Key Findings
1. Fresh "Hello World" baseline; zero implementation; `tests/` and `src/core/` and `README.md` all missing → all greenfield within this repo's conventions.
2. devenv is installed (v2.2.1). `devenv build`/`devenv test`/`devenv up` are the real entrypoints.
3. Odin `-file` build + `-collection` is the mechanism to split a testable core package out of the single-file binary. **Both build and test commands currently lack the collection flag — wiring it in is required and is the primary flake.nix change to unblock the code layout.**
4. `IN_Q_OVERFLOW` → full rescan; `IN_IGNORED`/`DELETE_SELF` → drop stale watch/entry; `IN_CLOSE_WRITE` in mask, NOT `IN_ONLYDIR`; initial sync right after `add_workspace` and on daemon startup (rev. 2).
5. odin-fmt pre-commit hook actively rewrites `.odin` files in place — ensure committed code is formatted.

## Gotchas
- **Duplicate-marker bug risk** — the flake transform must reuse/update an existing `# nws:` marker, never append a second one (idempotency).
- **Poll array mutation while iterating** — removing a closed client fd must use swap-remove/mark-sweep to avoid stale poll entries.
- **`-file` + collection**: while `-file` single-file build DOES work with imported collections, the flake's installPhase and enterTest must both carry the SAME `-collection` flag or compilation/tests fail. Keep collection name consistent everywhere.
- **AGENTS.md documents `enterTest = "odin test tests"` verbatim** — if a `-collection` flag must be added, keep the command still pointing at `tests/`.
- **`core:net` fd casting**: `TCP_Socket :: distinct Socket :: distinct i64`; plan notes `linux.Fd` is 32-bit here — transmute i64 → cast to `Fd` (verify truncation safely at wiring time).
- **store absolute/canonical paths** everywhere (real_path + dedupe), else inotify wd lookup and config round-trip break.
- Flake transform is line-based + fail-open: unparseable lines / nested attrs / multiline strings must be left untouched (never corrupt).

## Verified API facts (main-session check, Odin 2026-07a)
- **core:os**
  - `os.args` global `[]string` (also `os.get_args()`/`os.delete_args()`, "contextless").
  - `exists(path)->bool`, `is_dir(path)` (alias of `is_directory`), `getwd()/get_working_directory(allocator)->(string,Error)`.
  - `read_entire_file_from_path(name, allocator)->([]byte,Error)`; `os.read_entire_file` is an overload set.
  - `write_entire_file_from_string(name, data:string, perm:=Read_All+{.Write_User}, truncate:=true)->Error`; `os.write_entire_file` overload.
  - `make_directory(name, perm)->Error` (single dir) and `make_directory_all(path, perm)->Error` (parents). `rename(old,new)->Error`.
  - `user_home_dir(allocator)->(string,Error)`; `get_env_buf(buf,key)` / `get_env`.
  - ⚠️ **NO `os.real_path`** in modern core (only internal `_unix_realpath` in `old/`). Normalize paths manually (absolute + strip trailing slash / collapse `//`, `.`), don't call real_path.
- **core:net**
  - `listen_tcp(interface_endpoint: Endpoint, backlog:=1000)->(TCP_Socket, Network_Error)`
  - `accept_tcp(socket, options:=DEFAULT_TCP_OPTIONS)->(client: TCP_Socket, source: Endpoint, Accept_Error)`
  - `recv_tcp(socket, buf:[]byte)->(int, TCP_Recv_Error)`, `send_tcp(socket, buf)->(int, TCP_Send_Error)`
  - `dial_tcp` (overload set), `close(socket: Any_Socket)`, `set_blocking(socket: Any_Socket, should_block: bool)->(Set_Blocking_Error)`, `parse_endpoint(str)->(Endpoint,bool)`. `TCP_Socket :: distinct Socket`.
- **core:sys/linux** (import `linux`)
  - `inotify_init1(flags: Inotify_Init_Flags)->(Fd,Errno)`, `inotify_add_watch(fd, pathname:cstring, mask: Inotify_Event_Mask)->(Wd,Errno)`, `inotify_rm_watch(fd,wd)->Errno`.
  - `poll(fds: []Poll_Fd, timeout: i32)->(i32, Errno)`; `Poll_Fd struct{fd,events,revents:Fd_Poll_Events}`; `Fd_Poll_Events :: bit_set[..; u16]`. `read(fd, buf)->(int,Errno)`, `close(fd)->Errno`.
  - `Inotify_Event struct`, `Inotify_Event_Mask :: bit_set[Inotify_Event_Bits; u32]` (`.CREATE .DELETE .MOVED_TO .MOVED_FROM .CLOSE_WRITE .ATTRIB .Q_OVERFLOW .IGNORED .DELETE_SELF .MOVE_SELF ...`).
- **core:encoding/json**
  - `parse(data, allocator)->(Value, Error)`, `destroy_value(v)`, `unmarshal(data, ptr, spec, allocator)->Unmarshal_Error`, `marshal(v, opt, allocator)`.
  - `Value :: union{Null,Integer,Float,Boolean,String,Array,Object}`; `Object :: distinct map[string]Value`; `Array :: distinct [dynamic]Value`. **No `json.get_*` helpers** — access via type-assert, e.g. `obj := v.(json.Object); if p, has := obj["port"]; ... p.(json.Integer)`.
