# Context for: overlay backend — root flake that splices children into an external overlay's package set via `callPackage ./<child> {}` at a configured attrPath

## Relevant Files
- `src/nix_workspace.odin` (918 lines, `package main`) — CLI dispatch, daemon event loop, sync logic. The single integration point for the new backend.
- `src/core/root_flake.odin` (361 lines) — flake template generator + child-flake input parser + managed-root check.
- `src/core/config.odin` (131 lines) — Config schema (`port`, `workspaces: [dynamic]string`), hand-written pretty JSON.
- `src/core/state.odin` (211 lines) — canonical-URL persistence (workspace → repo → URL).
- `src/core/git_remote.odin` (132 lines) — `.git/config` origin URL reader (fail-open).
- `src/core/url.odin` (68 lines) — percent encode/decode for the wire protocol.
- `tests/root_flake_test.odin`, `tests/config_test.odin`, `tests/state_test.odin`, `tests/git_remote_test.odin` — golden/determinism tests.
- `flake.nix` — build: `odin build src/nix_workspace.odin -file -collection:nwscore=src -out:build/nws`; test: `odin test tests -collection:nwscore=src` plus `bash ${./tests/completions_test.sh}` in `enterTest`.

## Project Structure
Single binary (`package main` in `src/nix_workspace.odin`) importing one core package `nwscore:core` (`import "nwscore:core"`, referenced as `core.xxx`). Tests live in `tests/` as `package tests`. New generator code should go in `src/core/`; its tests in `tests/*_test.odin`.

## Key Findings — per area

### 1. sync_workspace & children detection (src/nix_workspace.odin)
- `sync_workspace :: proc(state: ^Daemon_State, path: string)` at ~line 690. Steps:
  1. Computes `fl_path = <path>/flake.nix`.
  2. `core.load_state(state_path(state))`.
  3. `local_repos(path)` (~line 880): first-level subdirs with `.git` **or** `flake.nix`. NOTE for overlay backend: children are Nix packages, not flakes; the `os.exists(own_flake)` check means a plain package dir without `.git` is invisible today. Detection likely needs a third condition or backend-specific rule.
  4. Builds `[dynamic]core.Child_Info`: name borrows `local[i]`; while clone present, reads `<child>/flake.nix` and calls `core.parse_flake_input_names` to fill `child.deps` (only used by flake backend sibling overrides). Calls `core.read_origin_url(child_dir)` for canonical URL and upserts state.
  5. Re-adds absent clones from state (pinned at persisted URL).
  6. Prunes state entries for unregistered workspaces.
  7. `generated := core.generate_root_flake(children[:])`.
  8. Write policy: no root flake → create; `!core.is_managed_root(existing)` → skip (log); byte-equal → skip; else `atomic_write(fl_path, generated, ..., "regenerated")` (~line 560).
- **Branch point**: `sync_workspace` is the only caller of both `generate_root_flake` and `parse_flake_input_names`. To switch templates per workspace you need a per-workspace backend setting reachable here (from config via `Daemon_State`), then dispatch to either `generate_root_flake(children[:])` or a new `generate_overlay_flake(children[:], overlay_cfg)`. For overlay mode the URL/state/deps block can be skipped entirely.
- Call sites that pass children arrays / Child_Info: only inside `sync_workspace` (construction of `children`, call to `generate_root_flake`). `Child_Info` itself is constructed nowhere else.
- Daemon regeneration triggers: `process_inotify_event` (~line 640) calls `sync_workspace` on CREATE/DELETE/MOVED_*/CLOSE_WRITE/ATTRIB of any kind on the root watch — nothing assumes children are flakes except `local_repos`'s optional `flake.nix` check and the deps parsing (which is fail-open/skipped when no child flake exists). Q_OVERFLOW rescans all workspaces.

### 2. Config schema (src/core/config.odin)
- `Config :: struct { port: int, workspaces: [dynamic]string }` (line ~9). **No per-workspace structure exists today** — workspaces are bare path strings.
- Parsing is manual `json.parse` → `json.Object`, `#partial switch` on variants; hand-written pretty JSON output in `build_config_json` with `json_escape`. Fail-open: missing/corrupt → defaults (`DEFAULT_PORT :: 17424`).
- Adding per-workspace config: options are (a) extend `Config.workspaces` to `[dynamic]Workspace_Config{name, backend, overlay_url, attr_path}` keeping JSON backward-compat (accept old string array form), or (b) add a separate top-level key e.g. `"overlays": { "<path>": {...} }`. `save_state_config` (~line 600, nix_workspace.odin) reconstructs Config from daemon state — it currently only copies paths; it would need to carry backend settings too (i.e., `Daemon_State` must remember them).

### 3. Generator (src/core/root_flake.odin)
- `generate_root_flake :: proc(children: []Child_Info, allocator := context.allocator) -> string` (~line 40): pure function, sorts by name (`slice.sort_by`), writes header `MANAGED_ROOT_HEADER :: "# nws-generated — do not edit"`, inputs section (path pins + optional `# nws:` marker comments), sibling overrides (`emit_sibling_overrides`), outputs delegation (`root_flake_outputs` — hardcoded Nix text delegating packages/devShells/apps/checks under `<child>-` prefixes).
- Parameterized already: names, urls, deps. Hardcoded: entire outputs template, input shape (`inputs.<name>.url`).
- Helpers reusable for overlay backend: `is_nix_identifier`, `nix_escape_string`, `write_attr_key`, sorting pattern. Not needed: `emit_sibling_overrides`, `parse_flake_input_names` (flake-only), markers.
- Adding a second template: keep determinism by (a) sorting children, (b) writing everything fresh from a builder, (c) returning `strings.clone(strings.to_string(b))`. Idempotency/write-skip already handled by byte comparison in `sync_workspace`. Suggest `generate_overlay_root_flake(children, cfg)` alongside; both share `MANAGED_ROOT_HEADER` so `is_managed_root` continues to gate user-authored roots regardless of backend.
- Tests (`tests/root_flake_test.odin`): golden exact-string tests (`test_root_flake_golden`, `test_root_flake_empty_children`, `test_root_flake_weird_names_escaped`), determinism test, sort test, marker-count test, `is_managed_root` edge cases, `parse_flake_input_names` test. New template gets analogous golden tests; existing ones untouched if `generate_root_flake` signature stays.

### 4. state / git_remote / url carry-over
- `state.odin`: exists solely to restore removed clones' inputs to their GitHub URL and to re-add absent clones to the root flake. For the overlay backend this is **not needed**: a removed clone simply stops being spliced (falls back to the upstream overlay package at attrPath). `lookup_url/upsert_url/prune_workspace` calls are all inside `sync_workspace` only — an overlay-mode branch can skip the whole state load/save block.
- `git_remote.odin` (`read_origin_url`, `trim_ini_line`, `section_is_origin`): only called from `sync_workspace`. Unneeded for overlay mode (unless you want to display origins); leave intact.
- `url.odin` (`encode`/`decode`): wire protocol only (register/unregister args). Carries over unchanged.
- State file location: `state_path()` (~line 555) = `dir(config)/state.json`.

### 5. Daemon regeneration assumptions
- Single non-recursive watch per workspace root, mask `{CLOSE_WRITE, CREATE, DELETE, MOVED_TO, MOVED_FROM, ATTRIB}` (no ONLYDIR — also catches edits to the root flake itself; the byte-equal skip prevents self-trigger loops).
- Only flake-ness assumptions: `local_repos` accepts dirs with `.git` OR `flake.nix`; `sync_workspace` optionally parses child `flake.nix` for deps; `generate_root_flake` emits `inputs.<name>.url = "path:./<name>"` which requires each child be a flake. Overlay mode removes all three assumptions for its workspaces.

### 6. Build/test wiring
- Build command embeds `-collection:nwscore=src`; tests run `odin test tests -collection:nwscore=src`. New core files just land in `src/core/` (package core) — no wiring change needed. Keep `enterTest` pointing at `tests/`; note `enterTest` also runs `bash ${./tests/completions_test.sh}`.

## Conventions
- Allocator use: explicit `context.allocator`; callers own returned strings and `delete` them; `fmt.tprintf` uses temporary allocator and is never freed manually; borrowed strings documented in comments (e.g., `Child_Info.name` borrowing `local[i]`).
- Fail-open everywhere: unreadable files, corrupt JSON, missing keys → defaults/skip, never crash.
- Atomic writes: temp file + rename in same dir (`atomic_write` in nix_workspace.odin, `save_config`, `save_state`); identical bytes → no write (prevents inotify loop).
- Deterministic output: sorted keys/children before emission (`sorted_map_keys`, `slice.sort_by`).
- Single-threaded poll event loop; no threads; no subprocesses.

## Call sites passing Child_Info / children arrays
- Construction: `sync_workspace` (nix_workspace.odin ~lines 705–785) — the ONLY place.
- Consumption: `core.generate_root_flake(children[:])` in `sync_workspace`; helpers inside root_flake.odin (`root_flake_outputs`, `emit_sibling_overrides`, `has_child_name`).
- Tests construct `[]core.Child_Info` literals directly.

## Gotchas
1. `local_repos` requires `.git` or `flake.nix` — plain package dirs (no .git, e.g. freshly created) are missed; decide detection rule for overlay mode.
2. `Daemon_State` carries only `port`, not full config — per-workspace settings need plumbing through `add_workspace`/`save_state_config` (which rebuilds Config from daemon state and would drop unknown fields unless preserved).
3. Backward compatibility of `config.json`/`state.json` format: existing users have string-array workspaces; loader must accept both forms (fail-open style suggests accepting old shape).
4. `Child_Info.deps` cleanup deletes the slice — reuse struct carefully if extended.
5. Root flake watch fires on the root's own CLOSE_WRITE; any non-byte-identical write loops forever. Byte-equal skip in `sync_workspace` is load-bearing — replicate for the overlay template.
6. Empty children still produce a valid managed flake; overlay empty case needs a defined minimal output too.
