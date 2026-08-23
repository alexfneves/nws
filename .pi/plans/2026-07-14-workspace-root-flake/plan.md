# Workspace Root Flake

**Date:** 2026-07-14
**Status:** Draft
**Directory:** /home/alexfneves/gits/nws

## Intent

Refactor nws so the daemon manages a single **generated `flake.nix` at each workspace ROOT**, instead of rewriting child repos' flakes in place. The root flake declares each cloned subfolder as a `path:./<name>` input (with a `# nws: <canonical-url>` marker preserving the original GitHub URL) and aggregates the children's outputs. **Child flakes are never modified.**

## User Story

As a workspace user, I want one generated flake at the workspace root that pins all my cloned repos locally and restores removed clones to their GitHub URLs, so that my repos' own flakes stay pristine and `nix build` / `nix develop` at the root sees everything.

## Behavior

### Happy Path
1. Daemon detects a workspace change (inotify event or registration) → calls `sync_workspace`.
2. `sync_workspace` enumerates first-level subdirs via existing `local_repos(path)`.
3. For each child, resolves its canonical URL (see Key Decisions).
4. `core.generate_root_flake(children)` produces a byte-deterministic root flake text.
5. If the root has no `flake.nix`, write the generated one. If the existing root flake is nws-managed (`# nws-generated` header), regenerate it atomically (tmp+rename). If it is user-authored, skip with a log line.
6. The write itself triggers inotify → re-sync regenerates identical bytes → no loop.

### Edge Cases & Error Handling
- No children yet → generate a minimal valid empty flake (still managed).
- Child without any discoverable canonical URL → emit input pinned to `path:./<name>` with no `# nws:` marker comment (fail-open; stays local).
- User deletes the generated root flake → next event regenerates it.
- User edits the generated root flake → regenerated on next event (documented; header warns "do not edit").
- Uncloned repo (dir absent): input falls back to the canonical URL from persisted state.
- Name collisions / invalid identifiers: sanitize dir names to valid Nix attrset keys; quote if needed.

## Scope

### In Scope
- New `core.generate_root_flake` replacing `sync_flake`'s line-rewrite role.
- Canonical-URL resolution: git remote + persisted state file (`~/.config/nws/state.json`, atomic writes like config).
- Managed-root detection via `# nws-generated` header marker.
- Output aggregation (packages, devShells, apps, checks) with namespaced keys.
- Migration: old scheme marked child flakes inline — leave those markers alone; daemon no longer touches child flakes. Old markers are inert comments.
- Tests for generator determinism, URL resolution fallbacks, managed/user-root detection.

### Out of Scope
- Recursive watching, threads, HTTP, multi-machine sync.
- Editing or validating children's flakes.
- `--override-input` ergonomics docs beyond a README note (workflows move to workspace root).

## Effort & Quality
- **Level:** production
- **Tests:** thorough (`tests/root_flake_test.odin`, exact-string golden output; determinism test = generate twice, compare)
- **Docs:** README section update + inline doc comments

## Ideal State Criteria

### Core Functionality
- [ ] ISC-1: Generated root flake declares every child dir as `inputs.<name>.url = "path:./<name>";`
- [ ] ISC-2: Each cloned child's canonical URL appears as a `# nws: <url>` comment on its input line
- [ ] ISC-3: Removing a child dir makes the next regeneration point its input at the stored canonical URL
- [ ] ISC-4: Root flake aggregates children's packages/devShells/apps/checks under `<child>-` prefixed output names
- [ ] ISC-5: Child flakes are byte-for-byte unmodified after daemon runs
- [ ] ISC-6: Regeneration is byte-idempotent (generate twice → identical)

### Edge Cases
- [ ] ISC-7: User-authored root flake (no `# nws-generated` header) is never modified
- [ ] ISC-8: Missing root flake is created on next event
- [ ] ISC-9: Child with no discoverable canonical URL gets no marker, stays `path:`-pinned
- [ ] ISC-10: Children are emitted in sorted order regardless of directory enumeration order

### Anti-Criteria
- [ ] ISC-A-1: No duplicate `# nws:` markers ever appear (reuse extract_marker semantics)
- [ ] ISC-A-2: No threads introduced; single-threaded poll loop preserved
- [ ] ISC-A-3: No non-atomic config/state writes

## Approach

Replace the line-rewrite transform with a **generator**: read-only scan of children → build a fresh root flake from a fixed template → compare with current root → atomic write if different. Deterministic because everything (ordering, formatting) comes from sorted inputs, not the environment.

### Key Decisions
1. **Canonical URL source:** primary = `git remote get-url origin` of the clone (authoritative while present); secondary/persistence = `~/.config/nws/state.json` mapping `{workspacePath: {repoName: url}}` updated whenever a remote is observed, so uncloned repos restore correctly. Parsing child flake inputs was rejected (fragile, may be a path flake itself).
2. **Aggregation policy:** namespaced prefixing (`packages.<sys>.<child>-<pkg>`) instead of raw merging — eliminates `.default` conflicts by construction; no heuristic winner-picking.
3. **Managed detection:** first-line `# nws-generated — do not edit` marker. Absent ⇒ user-owned, never touched.
4. **Self-trigger safety:** pure function of (sorted children + state); writing identical bytes skipped via changed-flag, and even a rewrite converges immediately.
5. **Old-marker migration:** do nothing; old inline markers in child flakes are harmless comments and child flakes are now off-limits.

### Architecture
- `src/core/root_flake.odin` (new): `generate_root_flake(children: []Child_Info, allocator) -> string`; `is_managed_root(text) -> bool`; `Child_Info {name, url, has_url}`.
- `src/core/state.odin` (new): load/save `state.json` (atomic, mirrors `config.odin` pattern).
- `src/nix_workspace.odin`: `sync_workspace` rewritten — enumerate children, resolve URLs (git remote via `os.execute`-free approach: read `.git/config` directly to stay dependency-light and non-blocking), call generator, atomic-write if managed/absent.
- `core/flake.odin`: reduced to `extract_marker` helper or deleted; tests updated accordingly.
- Git remote parsing: simple `[remote "origin"] url = ...` scan of `<child>/.git/config` — no subprocesses (single-threaded event loop must not block).

### Data Flow
inotify/socket event → sync_workspace → list children → for each: read `.git/config` (clone present) or state.json lookup (absent) → upsert state.json if new URLs seen → generate root text → compare & atomic-rename if changed.

## Dependencies
None new (Odin stdlib only: `core:strings`, `core:fmt`, `core:os`, `core:encoding/json`).

## Risks & Open Questions
- **`.git/config` parsing edge cases** (worktrees, `gitdir:` files): mitigate with conservative fail-open parse; unknown layout ⇒ no URL, path-pin only.
- **State file drift** (user moves workspaces): state keyed by absolute workspace path; stale entries pruned opportunistically during save.
- **Aggregated outputs need children evaluated by Nix** — children with broken eval will break root eval; accepted tradeoff (documented), since delegation is the point.
- Open question parked: whether checks aggregation should be opt-in to avoid slow CI-by-default (default: include; revisit if noisy).
