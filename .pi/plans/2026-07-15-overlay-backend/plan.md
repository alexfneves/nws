# Overlay Backend for nws

**Date:** 2026-08-23
**Status:** Approved
**Directory:** /home/alexfneves/gits/nws

## Intent
Add a second workspace backend to nws. Alongside the existing flake-delegation backend (default), workspaces can be configured with `"backend": "overlay"`: the generated root flake imports a user-configured overlay flake (e.g. nix-ros-overlay), imports nixpkgs with that overlay, and splices each child directory into the overlay's package set via `callPackage ./<child> {}` at a configured attrPath. Sibling dependency resolution is NOT done by nws — the package-set fixed point resolves it by attribute-name shadowing; removing a clone naturally falls back to the upstream overlay package.

## User Story
As a developer hacking on ROS (or other overlay-based) packages, I want my workspace of package checkouts to be exposed as overrides over an upstream overlay's package set, so that my modified packages shadow upstream ones while everything else comes from the overlay — without writing or maintaining any flake by hand.

## Requirements (agreed with user)
- Structured config, generic (no ROS-specific fields):
  ```json
  {"backend": "overlay", "overlays": [
    {"url": "github:lopsided98/nix-ros-overlay/master",
     "attrPath": "rosPackages.humble"}
  ]}
  ```
  Optional fields: per-entry `"overlayAttr"` (default `"default"`) and `"flake": false` (plain non-flake overlay expression → emit `import (builtins.fetchTarball ...)`); per-workspace `"nixpkgs": "<url>"`.
- Multiple overlay entries are future-proofing; v1 correctness targets the single-entry case but the generator loops over entries.
- **nixpkgs cascade (first match wins)**:
  1. Workspace-level `nixpkgs` URL → explicit `inputs.nixpkgs.url = <url>`.
  2. Else the first overlay flake exposes `inputs.nixpkgs` → root's `inputs.nixpkgs.follows = "<overlay>/nixpkgs"`.
  3. Else plain `import <nixpkgs>` (channel).
  (`pinNixpkgs` boolean dropped in favor of this cascade.)
- **Child detection (option B, evaluation-based):** candidates = every first-level directory plus their immediate subdirectories (monorepo coverage). Once per sync run `nix eval --json <overlay-url>#<attrPath> --apply 'builtins.attrNames'`; splice exactly the candidate paths whose basename is in that set, **deepest-match-wins** (if both a repo root and its subdir match, only subdirs are spliced). Cache attr-name sets in memory keyed by `(url, attrPath)`. Fail-open: eval failure logs a warning and keeps last known set; if never successful, splice **nothing** (never guess — a bad splice breaks evaluation of the whole root flake).
- Overlay-mode children need no `.git`, no `flake.nix`, no state.json canonical-URL tracking, no sibling-override logic.
- Full backward compatibility: existing configs (workspaces as plain string array) keep working unchanged and stay byte-stable on rewrite.
- Generated file keeps `# nws-generated — do not edit` header (`MANAGED_ROOT_HEADER` shared), deterministic sorted output, atomic write + byte-equal skip (load-bearing against inotify loops).

## Scope

### In Scope
- Config schema extension + backward-compatible loader/serializer + tests
- Daemon-state plumbing so per-workspace backend config survives `save_state_config`
- New overlay root-flake generator (core) + golden/determinism tests
- Pure candidate-matching helper (core) + tests
- `nix eval` runner (main binary) with caching + fail-open behavior
- Backend dispatch branch in `sync_workspace`
- Empty-children overlay case emits a valid minimal managed flake

### Out of Scope
- Dependency discovery between siblings (fixed-point handles it)
- CLI sugar for configuring overlay backends
- Threads / async eval (subprocess runs inline on the event loop, debounced by byte-equal skip)
- Modifying child flakes/dirs ever
- Any change to existing flake-backend behavior

## Effort & Quality
- **Level:** Production
- **Tests:** Thorough (golden + determinism for generator; unit tests for matcher and config round-trips)
- **Docs:** README section for overlay mode; inline comments

## Ideal State Criteria

### Core Functionality
- [ ] ISC-1: Config with old string-array workspaces loads identically to today and serializes byte-stably
- [ ] ISC-2: Object-form workspace config with `"backend": "overlay"` parses into Workspace_Config with entries
- [ ] ISC-3: `generate_overlay_root_flake` output starts with MANAGED_ROOT_HEADER, passes `is_managed_root`
- [ ] ISC-4: Generated flake applies overlay at configured attrPath and splices matched children via `callPackage ./<relpath> {}`
- [ ] ISC-5: nixpkgs cascade picks explicit url > follows-overlay > `<nixpkgs>` in correct precedence
- [ ] ISC-6: Matcher returns deepest matches only, sorted, for mono-repo layouts
- [ ] ISC-7: `sync_workspace` dispatches per backend kind; overlay path skips state.json/git_remote/deps entirely
- [ ] ISC-8: Overlay regeneration reuses atomic write + byte-equal skip (identical bytes → no write)

### Edge Cases
- [ ] ISC-9: Zero matched children still produces valid minimal managed overlay flake
- [ ] ISC-10: Failed `nix eval` keeps last cached attr set; never-successful eval splices nothing and logs warning
- [ ] ISC-11: Weird dir names are escaped correctly in generated Nix (same rigor as flake backend)
- [ ] ISC-12: User-authored root flake without managed header is never overwritten in overlay workspaces either
- [ ] ISC-13: Non-flake overlay entry (`"flake": false`) emits fetchTarball import form

### Anti-Criteria
- [ ] ISC-A-1: No threads introduced in the daemon
- [ ] ISC-A-2: Child directories/files are never written or modified
- [ ] ISC-A-3: Existing golden/determinism tests for `generate_root_flake` remain untouched and passing

## Approach
Approach A (approved): per-workspace struct config, backend dispatch in `sync_workspace`, generator as new core module alongside `root_flake.odin`. Subprocess (`nix eval`) lives in the main binary; matching stays pure in core for testability.

### Key Decisions
- Per-workspace `Workspace_Config` inside `Config.workspaces` rather than side-table — one source of truth (user chose A).
- nixpkgs cascade replaces boolean flag — better generic behavior across overlays.
- Eval-based detection with fail-open-to-empty — user accepted cost; correctness over guessing.
- Deepest-match-wins prevents double-splicing mono-repo roots and their subdirs.

## Architecture

```
config.json ──load──▶ [dynamic]Workspace_Config ──▶ Daemon_State.ws_cfgs (map path→cfg)
                                                        │
inotify event / register ──▶ sync_workspace(state, path)
                              ├─ kind == .flake   → existing pipeline (unchanged)
                              └─ kind == .overlay
                                   ├─ scan_candidates(path)          [main pkg]
                                   ├─ run_nix_eval(entry) + cache    [main pkg]
                                   ├─ core.match_overlay_children()  [core, pure]
                                   └─ core.generate_overlay_root_flake(matched, cfgs)
                                        → atomic_write + byte-equal skip (shared)
```

### Components
1. **`src/core/config.odin`** — extend:
   ```odin
   Workspace_Kind :: enum { flake, overlay }
   Overlay_Entry :: struct { url, attr_path, overlay_attr: string, is_flake: bool }
   Workspace_Config :: struct {
       name: string,
       kind: Workspace_Kind,
       overlays: [dynamic]Overlay_Entry,
       nixpkgs_url: string,   // "" = cascade decides
   }
   ```
   Loader accepts old `[string]` form (→ `.flake` kind) and object form. `build_config_json` emits objects only for non-default (overlay) workspaces so legacy configs stay byte-stable.
2. **`src/nix_workspace.odin`** — `Daemon_State` gains `ws_cfgs: map[string]core.Workspace_Config`; `add_workspace` / `unregister` / `save_state_config` (~600) carry it through (fixes drop-unknown-fields gotcha). `sync_workspace` branches once at top on kind; overlay branch ~40 lines. Helpers: `scan_candidates` (first-level dirs + immediate subdirs), `run_nix_eval` (`nix eval --json <url>#<attr_path> --apply 'builtins.attrNames'`, parse via `core:encoding/json`, warn+cache-fail-open). Reuse `atomic_write`, byte-equal skip, `is_managed_root` gate.
3. **`src/core/overlay_flake.odin`** (new) — `generate_overlay_root_flake(matched: []Overlay_Child, cfg: Workspace_Config, allocator := context.allocator) -> string`. Emits: header; inputs (`<name>.url` per flake overlay entry; optional `nixpkgs.url` or `nixpkgs.follows = "<overlay>/nixpkgs"` per cascade); pkgs import applying each overlay (`overlays.<overlayAttr>` or fetchTarball-import form); outputs exposing each configured attrPath, splicing children under it with `callPackage ./<relpath> {}`. Sorted children/attrs, fresh builder, shares `MANAGED_ROOT_HEADER`. Reuse helpers: `is_nix_identifier`, `nix_escape_string`, `write_attr_key`, sort pattern from `root_flake.odin`.
4. **`src/core/match_children.odin`** (new) — `match_overlay_children(candidates: []string, attr_names: map[string]bool) -> []string`: basename ∈ attr_names; deepest-match-wins; sorted output. Pure, fully unit-testable offline.
5. **Tests** — `tests/overlay_flake_test.odin` (golden exact-string, determinism, empty-children, escaping, non-flake entry, nixpkgs-cascade variants), `tests/match_children_test.odin` (flat match, monorepo deepest-win, no-match-empty), extensions to `tests/config_test.odin` (legacy array load+byte-stable save, object form load/save).

### Data Flow
register/config-load populates ws_cfgs → inotify event on overlay workspace root → sync_workspace: scan dirs → eval/cached attr names → match → generate → atomic write (skip if identical/unmanaged) → next poll cycle. No state.json interaction in overlay mode.

## Dependencies
- None new beyond `nix` being on PATH for overlay workspaces (fail-open when absent).

## Risks & Open Questions (premortem)
| Risk | If wrong / mitigation |
|---|---|
| `nix eval` blocks the event loop on slow/network fetch | Accepted: debounced by byte-equal skip; fail-open timeout not added in v1 — revisit if painful |
| `save_state_config` drops backend settings | Explicitly plumbed via ws_cfgs; covered by config round-trip tests |
| Legacy config rewrite changes bytes | Emitter writes objects only for overlay workspaces; test asserts byte-stability (ISC-1) |
| Wrong splice breaks whole-flake evaluation | Never guess: fail-open-to-empty (ISC-10) |
| Deepest-match rule surprises users (root repo also matched) | Documented; only subdirs spliced when both match |
| `nix eval` output format drift | Parse defensively; corrupt JSON treated like failure (fail-open) |

## Manual Verification Checklist (update after implementation)
1. `nix build .#main && devenv test`
2. Register an overlay workspace (ros-style config); confirm generated flake has header, follows nixpkgs, splices a sample package dir.
3. Touch a file in a child dir → regenerates identically (byte-skip, no loop).
4. Delete a child dir → attr disappears, falls back to upstream.
5. Offline start → warning logged, empty splice flake emitted.
6. Legacy config (string array) loads and saves byte-stable.
