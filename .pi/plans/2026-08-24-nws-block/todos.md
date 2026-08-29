# Todos — nws-block flake ownership

Plan: `.pi/plans/2026-08-24-nws-block/plan.md`
Tag: `nws-block`
DO NOT run `devenv build` — use `nix build .#main`. Run `devenv test`/`odin test tests -collection:nwscore=src` after each commit.

## T1: `src/core/flake_block.odin` — markers, finder, patcher (pure)

New core file. Primitives (fail-open, line-based, no Nix evaluator):
```odin
NWS_BLOCK_BEGIN :: "# nws block — managed by nws; do not edit"
NWS_BLOCK_END   :: "# /nws block"

// find_nws_block returns the byte span of the block (BEGIN..END lines inclusive)
// and ok. Absent → ok=false, start/end both -1. Malformed (END without BEGIN,
// BEGIN without END, or BEGIN==END) → ok=false, never corrupt.
find_nws_block :: proc(text: string) -> (start, end: int, ok: bool)

has_nws_block :: proc(text: string) -> bool

// patch_flake returns (new_text, true) when the insert/update succeeded, or
// (existing unchanged, false) when the file cannot be safely patched
// (no top-level balanced `{`/`}` boundary, or marker-malformed → fail-open).
patch_flake :: proc(existing, block: string) -> (string, bool)
```
- `find_nws_block`: line-scanned (mirror `count_braces` / `parse_input_line_head`
  style in root_flake.odin. Use `strings` helpers). Find the first line whose
  trimmed text == `NWS_BLOCK_BEGIN`, then the next line == `NWS_BLOCK_END`.
  Returns byte offsets covering from the BEGIN line (incl. its newline) through
  the END line.
- `patch_flake`: 
  - block present → `before + block_body + after` where block_body is inserted
    between the markers; i.e. replace the span [start,end) with the new block
    (BEGIN line + new block body + END line) — actually the new block replaces
    the whole marked region so user content between old BEGIN/END is dropped
    (nws owns that region).
  - block absent → find injection point: scan for the LAST top-level `}` line
    (the flake's final closing brace, mirroring run.sh `grep -n '^  };$'` but
    generalized to `}` at top level). Insert `before_last_brace + "\n" + block +
    "\n" + "\n" + last_brace`. Return unchanged+false if no top-level `}`.
- Determinism: same inputs → same bytes.

Tests `tests/flake_block_test.odin`: find present/absent/malformed/duplicate;
patch inject into a user flake (all bytes preserved), update existing block
(user bytes outside preserved), unparseable (no top-level `}`) → unchanged+false,
empty block body.

Accept: ISC-1, ISC-2, ISC-8, ISC-9.

## T2: generator refactor — emit a BLOCK BODY, not a whole file

In `src/core/overlay_flake.odin` and `src/core/root_flake.odin`:
- Add a parameter/flag so each `generate_...` can emit ONLY the nws block body
  (from a `# nws block` BEGIN to END, i.e. `write_block` that writes
  `BEGIN\n` + `<the owned part, body>` + `END\n`). The owned "body" is the
  current whole-file content minus the top-level `{`/`}` scaffold and minus
  the return set's closing `  };` — minus what now lives in the surrounding
  file — i.e. BEGIN + inputs + `outputs ... let ... in {` + generated output
  attrs + END (the outputs return set is LEFT OPEN at END; the file closes it
  with `  };` and closes the flake with `}`).
- For overlay: the body = the current `inputs`(if any) + `outputs = ...` inner
  content. For flake-delegation: `inputs` + `outputs` inner content.
- Keep ALL existing emitted internals byte-identical (childCalls/spliced0/
  overrideScope'/packages/default for overlay; children delegation for
  flake-backend) so substring tests survive. ONLY the wrapping changes.
- Create path: `generate_..._root_flake` = `{\n` + block + `  };\n}\n`, and
  `patch_flake("", block)` appends the same `  };\n}\n` scaffold (block itself
  is left-open).
- Provide `generate_block(...)` wrappers that return the block text, and keep
  `generate_..._root_flake` working for backwards-compat tests OR update tests.
  Decision: introduce `generate_root_block`/`generate_overlay_block` returning
  the marked block; keep `is_managed_root` tests replaced by `has_nws_block`.

Accept: ISC-3, ISC-7 (stable names).

## T3: daemon write tails — patch then byte-skip

`src/nix_workspace.odin` `sync_workspace` (1080-1099) + `sync_workspace_overlay`
(1157-1175):
```
block := core.generate_<backend>_block(...)
existing, rerr := os.read_entire_file(...)
if rerr != nil {
    // no flake → create from block
    written, ok := core.patch_flake("", block)  // or build minimal flake
    atomic_write(fl_path, written, ...); return
}
new_text, ok := core.patch_flake(string(existing), block)
if !ok { log_line(state.logging, "leaving flake alone: %s", fl_path); return }
if string(existing) == new_text { return }   // loop guard on PATCHED result
atomic_write(fl_path, new_text, state.logging, "regenerated")
```
- Remove the `is_managed_root` gate; a user flake is serviced (inject), not skipped.
  Injecting is refused (fail-open, logged) when the file already declares its own
  top-level `inputs`/`outputs` — a duplicate-attribute flake would break eval
  (discovered live; see plan "Block boundary" note).
- For create path, `patch_flake("", block)` builds `{\n` + block + `  };\n}\n`
  (block is left-open; scaffold closes the return set and the flake).

Accept: ISC-4, ISC-5, ISC-6, ISC-10, ISC-A2, ISC-A3.

## T4: gate replacement + tests

- Replace `is_managed_root` with `has_nws_block` (or repurpose name). Update all
  call sites + tests.
- Rewrite full-file golden tests in `tests/root_flake_test.odin` +
  `tests/overlay_flake_test.odin` around block-in-file fixtures:
  - golden = a user flake shell + the nws block; assert user bytes preserved after
    patch; assert `patch_flake(existing, block)` round-trips deterministically; 
    assert the block injects/updates while user attrs stay.
  - replace `is_managed_root(got)` asserts with `has_nws_block`.
  - keep substring tests (override conditional, cascade, overrideScope', sibling
    wiring, default output) — they assert inner block content and should survive.
- Keep `test_parse_flake_input_names` (child-flake parser, unaffected).
- New tests already in T1.

Accept: all ISCs end-to-end.

## T5: README + example cleanup

- README: rewrite "nws owns whole file" → "nws creates the flake if absent,
  otherwise injects/updates a marked nws block; user content outside the block
  is never touched; the `# /nws block` END marker sits inside the outputs
  return set, so user output attrs (devShells) live below it and survive".
  Document the block markers + stable binding names + fail-open (unparseable or
  own-inputs/outputs flake left alone). [DONE]
- `examples/overlay-ros/run.sh`: the injected devShell no longer fights
  regeneration. Inject ONCE below the `# /nws block` END marker (it survives
  regen — verified live). Remove the retry loop + "drops it (expected)"
  warnings; keep the marker-guard idempotency. [DONE]
- `examples/overlay-ros/README.md`: update the "dev shell is a user layer / regen
  drops it" language. [DONE]

Accept: docs consistent. [DONE]

## T6: verify + commit

- `nix build .#main`, `devenv test` (104 tests green). [DONE]
- Live daemon smoke (this session): overlay + delegation workspaces — devShell
  injected below END survives a resync and a block-content change; created
  shapes are valid/evaluable flakes; a user flake with its own inputs/outputs
  is refused unchanged (logged) and still evaluates. [DONE]
- odinfmt; ONE commit (T5 + boundary fix, per plan owner decision). [PENDING]