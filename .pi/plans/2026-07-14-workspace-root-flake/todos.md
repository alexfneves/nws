# Todos — workspace-root-flake

Tag: `workspace-root-flake` · Plan: `.pi/plans/2026-07-14-workspace-root-flake/plan.md`
(Note: todo-tool unavailable in planning session; persisted here for orchestrator ingestion.)

## T1: Add `core/state.odin` — persisted canonical-URL state — DONE ✅
- Files: `src/core/state.odin` (new), `tests/state_test.odin` (new)
- Mirror the atomic-write pattern in `src/core/config.odin` (temp file + rename, `encoding/json`).
- Types + shape:
  ```odin
  package core
  State :: struct { workspaces: map[string]map[string]string } // wsPath -> repoName -> canonical url
  load_state :: proc(path: string, allocator) -> (State, bool)
  save_state :: proc(path: string, s: ^State, allocator) -> bool // atomic
  upsert_url :: proc(s: ^State, ws, repo, url: string)
  ```
- Acceptance: save→load roundtrip equals input; save is atomic; stale workspace entries prunable.
- Anti-pattern: do NOT write state non-atomically (ISC-A-3).

## T2: Add `core/root_flake.odin` — deterministic generator — DONE ✅
- Files: `src/core/root_flake.odin` (new), `tests/root_flake_test.odin` (new)
- Reference: reuse marker semantics from `src/core/flake.odin:extract_marker`; children enumeration already exists in `src/nix_workspace.odin:750 local_repos`.
- Shape:
  ```odin
  Child_Info :: struct { name, url: string, has_url: bool }
  generate_root_flake :: proc(children: []Child_Info, allocator) -> string
  is_managed_root :: proc(text: string) -> bool // first line "# nws-generated"
  ```
- Output: header `# nws-generated — do not edit`; sorted children; each input:
  `  <name>.url = "path:./<name>"; # nws: <url>` (marker omitted when `!has_url`);
  outputs section delegating `packages/devShells/apps/checks` with `<child>-` prefix (ISC-1,2,4,10).
- Tests: golden exact-string output; generate-twice determinism; unsorted input → sorted output; no-URL child; no duplicate markers.
- Anti-pattern: do NOT iterate directory order — sort names (ISC-10).

## T3: Git-remote resolution via `.git/config` parse — DONE ✅
- Files: `src/core/git_remote.odin` (new), `tests/git_remote_test.odin` (new)
- Read `<child>/.git/config`, find `[remote "origin"]` section, return its `url =` value. Fail-open: any unexpected layout → no URL. No subprocesses (single-threaded event loop must not block).
- Tests: normal config, worktree-style `.git` file (returns none), missing file, multiple remotes (origin wins).
- Acceptance: ISC-9.

## T4: Rewrite `sync_workspace` to generate-and-write root flake — DONE (commit e6c9ebc)
- Files: `src/nix_workspace.odin` (modify `sync_workspace` ~line 711)
- New flow: `local_repos(path)` → for each child: `git_remote` (if clone present) else `state.json` lookup → upsert state → `generate_root_flake` → if root flake absent or `is_managed_root`, atomic-write when changed; else log skip.
- Reference for atomic write + changed-flag: existing `sync_workspace` body and `core.sync_flake` call site (`src/nix_workspace.odin:711-746`).
- Acceptance: ISC-5,6,7,8; child flakes untouched; no rewrite when bytes identical (no self-trigger loop).
- Anti-pattern: do NOT modify child flakes; do NOT call the old `core.sync_flake` rewrite path.

## T5: DONE — Retire the line-rewrite transform + migrate tests
- Files: `src/core/flake.odin` (reduce to `extract_marker` or delete), `tests/flake_test.odin` (replace with generator tests or delete if superseded by T2 tests)
- Keep only helpers still referenced (marker extraction). Ensure `odin build src/nix_workspace.odin -file -collection:nwscore=src` still compiles.
- Acceptance: `nix build .#main` and `devenv test` pass; no references to removed procs.

## T6: README + manual verification checklist
- Files: `README.md`, plan's manual checklist
- Document: root-flake model, "workflows move to workspace root / --override-input", old inline child markers are inert, state file location `~/.config/nws/state.json`, managed-header warning.
- Acceptance: `nix build .#main` + manual smoke: `result/bin/nws service` in a temp workspace with two child repos → root flake generated, children unmodified, `LIST` socket works.
