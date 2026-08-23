# Code Review — Workspace Root Flake Refactor (T1–T6)

**Reviewed:** commits 94e5914..382e006 (core/state.odin, core/root_flake.odin, core/git_remote.odin, rewritten sync_workspace, removal of flake.odin/flake_test.odin, docs)
**Verdict:** APPROVED (with minor follow-ups, none blocking)

## Summary
The refactor cleanly replaces the child-flake line-rewrite with a deterministic root-flake generator. Child flakes are never written anywhere in the new code paths; the generator is pure and sorted; writes are atomic and skipped on identical bytes; the poll loop stays single-threaded with no subprocesses.

## Verification
- `nix build .#main` — succeeds.
- `devenv test` (`odin test tests -collection:nwscore=src`) — 25/25 pass.
- One memory-tracking warning in tests: 184B leak attributed to `tests/git_remote_test.odin:124` (`contents` from `strings.join` never freed). Test-only, cosmetic.

## Invariant checks
- **Child flakes untouched:** confirmed — only `read_origin_url` touches children, and it reads `<child>/.git/config` read-only. No write path reaches a child dir.
- **Byte-idempotent root flake:** `generate_root_flake` is a pure function of sorted children; `sync_workspace` compares existing bytes and returns early on equality → no self-trigger loop. The `.tmp` write does enqueue extra inotify events, but the next sync sees identical bytes and skips. ✔
- **User-authored root:** `is_managed_root` gates every regeneration path; missing file is created, unmanaged file only logs. ✔
- **Atomicity:** both `atomic_write` (flake) and `save_state` use tmp+rename in the same directory. ✔
- **No subprocesses/threads:** git remote via direct `.git/config` parse; single poll loop intact. ✔
- **Fail-open parsing:** `read_origin_url`, `load_state`, `local_repos` all return empty/false on bad input; daemon never panics on corrupt state.json or worktree-style `.git`. ✔

## Findings

### [P2] Plan deviation: child names are not sanitized/quoted before embedding in Nix source
**File:** `src/core/root_flake.odin:60-72`
**Issue:** The plan's edge-case section says "sanitize dir names to valid Nix attrset keys; quote if needed." Names are interpolated raw into both a Nix string literal (`"path:./<name>"`) and an identifier position (`inputs.${child}` resolves dynamically so that part is fine). A directory whose name contains `"`, `\`, or `$` would produce broken or attacker-influenced Nix text in the generated file. Exploitability is low (requires an oddly named directory inside the user's own workspace), but the generated flake can become syntactically invalid.
**Suggested Fix:** Reject/skip children whose name fails a conservative `[A-Za-z0-9._-]+` check (log a line), or escape `"`/`\`/`${` when writing string literals.

### [P2] State entries for unregistered/deleted workspaces are never pruned by the daemon
**File:** `src/nix_workspace.odin:586-598` (`remove_workspace`), plan "State file drift"
**Issue:** `prune_workspace` exists and is tested but is only called from tests. `remove_workspace`/`drop_workspace_wd` leave the workspace's URL entries in `state.json` forever. The plan called for "stale entries pruned opportunistically during save."
**Suggested Fix:** Call `core.prune_workspace(&state.url_state, path)` in `remove_workspace` and `drop_workspace_wd` before persisting.

### [P3] Test leak: unfreed `strings.join` result in git_remote_test
**File:** `tests/git_remote_test.odin:124`
**Issue:** Odin's test runner memory tracking reports a 184B leak for `contents` allocated with the default allocator and never deleted. Harmless but noisy on every test run.
**Suggested Fix:** `defer delete(contents)` or allocate from `context.temp_allocator`.

### [P3] `defer os.remove(tmp)` after successful rename in `save_state`
**File:** `src/core/state.odin:96`
**Issue:** After a successful rename, the deferred remove targets a nonexistent path (error silently ignored). Harmless; just slightly misleading control flow.
**Suggested Fix:** Move the remove into the error branches, or ignore.

## What's Good
- Memory discipline in `sync_workspace` is careful and well-commented (heap `strings.concatenate` vs temp-allocator `tprintf`; borrow-vs-clone of state map keys documented at each site; defer ordering verified correct — children urls freed before their sources).
- Fail-open philosophy is applied consistently and matches the plan exactly (worktree `.git` files explicitly refused rather than followed).
- Deterministic JSON serialization via `sorted_map_keys` means even the state file is byte-stable.
- Tests cover the important behaviors: golden output, double-generate determinism, managed/user detection, origin-parse edge cases (comments, whitespace, non-origin sections), state round-trip including corrupt-file handling.
- Old inline `# nws:` markers correctly left inert; legacy transform fully deleted rather than kept half-alive.
