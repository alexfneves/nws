# Ownership inversion: user-owned root flake.nix with a managed nws block

**Date:** 2026-08-24
**Status:** Ready for implementation
**Directory:** /home/alexfneves/gits/nws

## Intent

Invert flake ownership. Today nws owns the WHOLE root `flake.nix` (a
`# nws-generated — do not edit` first line marks the entire file as managed;
regeneration rewrites every byte, wiping any user content — devShell, devenv,
`description`, a hand-written attr). The plan makes the root flake **user-owned**:
nws **creates** `flake.nix` when it does not exist, and when it does exist nws
**parses** it and **injects/updates only its own managed block**, leaving all
user content (their inputs, devShells, devenv, `description`, `nixConfig`, …)
untouched across regenerations.

The user explicitly framed it: "The nws should be able to parse the current
flake.nix and inject ONLY in the parts that matter for it. Rather than having a
block for the user, we need a block for the nws in the flake.nix." And: "If the
flake doesn't exist initially, nws creates it. Otherwise it needs to inject data
onto it."

## User Story

As an overlay (or flake-delegation) workspace user, I want to `nws register`, add
my own attrs to `flake.nix` (a ROS devShell, devenv, etc.), and have those
survive any nws regeneration — so I can layer user content on a managed flake
without fighting the daemon.

## Behavior

### Create path (flake absent)
`flake.nix` does not exist → nws writes a fresh file wrapping ONLY its managed
block in a valid top-level `{ ... }`. The block is LEFT OPEN where the outputs
return set closes: the file is `{\n` + block + `  };\n}\n` (block ends with the
`# /nws block` END marker inside the return set, then `  };` closes the set and
`}` the flake). User edits it later freely — their attrs go below the END
marker and survive.

### Inject path (flake present, no nws block)
`flake.nix` exists without an nws block → nws finds a safe injection point
(before the final top-level closing `}`) and inserts its block, preserving every
existing byte. A flake that already declares its own top-level
`inputs`/`outputs` (devenv-style) is **refused** fail-open: injecting the block
would duplicate those attributes and break evaluation.

### Update path (flake present, nws block exists)
`flake.nix` has an nws block → nws replaces the region between the block markers
with the freshly generated block body. All user content outside the markers is
byte-preserved — including user output attrs written below the END marker
inside the return set, which is the devShell/app persistence point.

### Loop guard
The write is only performed if the **patched** result differs from the existing
file (`patch(existing, block) != existing`), so atomic_write's rename does not
self-trigger an infinite regen loop (bytes identical → skip).

### Edge cases / fail-open
- Flake present + unparseable (no top-level `{`/`}` boundary) → leave file alone,
  log, never corrupt.
- Flake present + own top-level `inputs`/`outputs` → refuse to inject (duplicate
  attrs would break eval); log, leave file alone.
- Block markers present but malformed/duplicate → fail-open, never corrupt;
  treat as "no block" for injection or log + skip.
- Zero children / channel mode → the block (with empty child set) still injects.

## Scope

### In Scope
- Block marker constants + finder + patcher in `src/core`.
- `is_managed_root` → `has_nws_block` gate replacement (or keep name, change
  meaning, update call sites).
- Daemon write tails in `sync_workspace` + `sync_workspace_overlay`:
  `patch(existing, block)` then byte-skip on patched equality.
- Refactor both generators to emit an nws **block body** (their own part) rather
  than a whole file; the file shell (brace, preamble, user attrs) comes from the
  existing file or a minimal default.
- **Block boundary (corrected 2026-08-29):** the block is LEFT OPEN at the END
  marker — `# /nws block` sits INSIDE the outputs return set, after the
  nws-generated output attrs. User output attrs (devShells, …) written below
  the END marker belong to the return set and survive regeneration; the `};`
  closing the return set and the flake's `}` live in the surrounding file.
  The create scaffold (`generate_*_root_flake`, `patch_flake("", block)`)
  appends `  };\n}` — never the block. Injecting into a flake that already
  declares its own top-level `inputs`/`outputs` is refused fail-open (a
  duplicate-attribute flake would break eval).
- Stable binding names contract: user attrs reference block internals
  (`spliced0`, `childCalls0`, `base0`, `overlay0`, `nixpkgs`) — keep these names
  stable so user devShells written against one generation survive the next.
- Rewrite affected golden tests; add injection/finder/patcher tests; README updates.

### Out of Scope
- Splitting the nws block across multiple file regions (block stays self-contained:
  inputs + sibling wires + outputs + default together).
- Per-child `# nws:` markers moving out of the block (they stay inside).
- Any UI/CLI change (register flags unchanged).

## Constraints
- Single-threaded, fail-open, odinfmt, deterministic; byte-stable writes only when
  the *patched* file changes.
- The nws block must remain self-contained and the daemon must never corrupt a
  user file.
- Existing flake-backend golden behavior (delegation namespacing, sibling wiring)
  preserved inside the block.

## Ideal State Criteria

### Core Functionality
- [ ] ISC-1: `find_nws_block(text) -> (start, len)` finds the marker pair; absent → inject point.
- [ ] ISC-2: `patch_flake(existing, block)` returns existing-with-block-injected-or-updated; unparseable or own-inputs/outputs flake → returns existing unchanged (fail-open).
- [ ] ISC-2b: user output attrs below the END marker survive `patch_flake` (devShell persistence test).
- [ ] ISC-3: Create path writes a valid minimal flake with the block (`{\n` + block + `  };\n}\n`; block itself is left-open).
- [ ] ISC-4: Inject path preserves all existing bytes, adds block.
- [ ] ISC-5: Update path replaces only the block region; user bytes outside preserved.
- [ ] ISC-6: Daemon byte-skip on `patch(existing, block) == existing` (no regen loop).
- [ ] ISC-7: Stable binding names (`spliced0`, `childCalls0`, `base0`, `overlay0`, `nixpkgs`) — pinned by tests.

### Edge Cases
- [ ] ISC-8: Unparseable file → fail-open (unchanged, logged).
- [ ] ISC-9: Malformed/duplicate markers → fail-open.
- [ ] ISC-10: Empty child set / channel mode still injects a valid block.

### Anti-Criteria
- [ ] ISC-A1: No user content is ever rewritten or dropped by nws.
- [ ] ISC-A2: No infinite regen loop (patched-byte guard).
- [ ] ISC-A3: No corruption of a user-authored flake (fail-open on unparseable).

## Approach

Refactor in `src/core`:
1. New `src/core/flake_block.odin` (or extend `root_flake.odin`/`overlay_flake.odin`):
   - `NWS_BLOCK_BEGIN :: "# nws block — managed by nws; do not edit"`
   - `NWS_BLOCK_END :: "# /nws block"`
   - `find_nws_block(text) -> (start, end, ok)` (line-based scan)
   - `has_nws_block(text) -> bool`
   - `patch_flake(existing, block) -> (string, bool)`
2. Both generators gain a mode/param to emit the **block body** (from `BEGIN` to
   `END` inclusive) instead of a whole file. The whole-file shape is assembled by
   a new `build_flake(block, existing)` that wraps a minimal `{ ... }` when creating
   or splices into the existing file when present.
3. Daemon write tail (both syncs) becomes:
   ```
   generated_block := core.generate_..._block(...)
   existing, rerr := os.read_entire_file(...)
   if rerr != nil {
       core.atomic_write(fl_path, core.build_flake(generated_block, ""), ...)  // create
       return
   }
   new, ok := core.patch_flake(string(existing), generated_block)
   if !ok { log("leaving unparseable flake alone"); return }
   if string(existing) == new { return }   // loop guard on PATCHED result
   atomic_write(fl_path, new, ...)
   ```
4. Replace `is_managed_root` prefix gate with `has_nws_block`; update the two call
   sites (nix_workspace.odin:1091, 1168) to always attempt patch (a user file is now
   serviced, not skipped).
5. Tests, README, example cleanup.

## Files touched
- `src/core/root_flake.odin`, `src/core/overlay_flake.odin` (block emission + new helpers)
- `src/nix_workspace.odin` (write tails + gate)
- `tests/root_flake_test.odin`, `tests/overlay_flake_test.odin` (rewritten goldens + new tests)
- `README.md`, `examples/overlay-ros/README.md`, `examples/overlay-ros/run.sh` (ownership language)

## Risks
- Stable binding names become a compatibility contract (see ISC-7).
- Block must stay self-contained / single-region.
- Patching must be byte-precise or the loop guard or user content breaks — heavy test focus.

## Effort
Production-level; both backends + daemon + tests + docs.