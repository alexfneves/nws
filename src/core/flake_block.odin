package core

import "core:strings"

// NWS_BLOCK_BEGIN marks the start of the region of a root flake owned by nws.
// A root flake containing a well-formed BEGIN…END pair is serviced in place:
// the span [BEGIN, END) is nws's own output and gets replaced wholesale on
// every regeneration; everything outside the span is the user's and is never
// touched.
//
// The block body is LEFT OPEN at the END marker: generators emit the flake's
// `inputs` section and an `outputs` expression whose return attrset stays
// open (ending in `in {` plus the nws-owned output attrs), so the
// `# /nws block` END line sits INSIDE that return set. User output attrs
// (devShells, apps, ...) written below the END marker still belong to the
// return set and survive regeneration; the `};` that closes the return set
// and the flake's final `}` live in the surrounding file, never in the block.
NWS_BLOCK_BEGIN :: "# nws block — managed by nws; do not edit"

// NWS_BLOCK_END marks the end of the nws-owned region.
NWS_BLOCK_END :: "# /nws block"

// find_nws_block locates the first well-formed nws block in text: the first
// line whose trimmed content equals NWS_BLOCK_BEGIN, then the next line whose
// trimmed content equals NWS_BLOCK_END. The returned byte span [start, end)
// covers the BEGIN line through the END line inclusive, each including its
// trailing newline when present.
//
// ok is false — and start/end are both -1 — when either marker is missing or
// the markers are malformed/duplicated (END without BEGIN, BEGIN without END,
// or a second BEGIN before any END); the block is then treated as absent and
// the file left alone (fail-open, never corrupt).
find_nws_block :: proc(text: string) -> (start, end: int, ok: bool) {
	start, end = -1, -1
	begin_off := -1
	n := len(text)
	i := 0
	for i <= n {
		j := i
		for j < n && text[j] != '\n' {
			j += 1
		}
		t := strings.trim_space(text[i:j])
		if begin_off == -1 {
			if t == NWS_BLOCK_BEGIN {
				begin_off = i
			}
		} else {
			// Past the BEGIN line: the next END (or a duplicated BEGIN)
			// decides the outcome.
			if t == NWS_BLOCK_BEGIN {
				// Two BEGINs before an END — ambiguous, fail open.
				return
			}
			if t == NWS_BLOCK_END {
				end = j
				if j < n && text[j] == '\n' {
					end = j + 1
				}
				return begin_off, end, true
			}
		}
		if j >= n {
			break
		}
		i = j + 1
	}
	return
}

// has_nws_block reports whether text contains a well-formed nws block.
has_nws_block :: proc(text: string) -> bool {
	_, _, ok := find_nws_block(text)
	return ok
}

// patch_flake applies a complete block (its own BEGIN marker line, body, and
// END marker line — owned by the caller, borrowed here) to existing:
//
//   - block present in existing → the marked span [BEGIN, END) is replaced
//     by block verbatim. Everything the user wrote below the END marker
//     (their own output attrs inside the outputs return set, plus the `};`
//     and `}` closers) is byte-preserved across regenerations — this is
//     where user devShells/apps live and survive.
//   - no block present → the block is injected before the last top-level
//     closing `}` (the flake's outer scope): `before + "\n" + block + "\n" +
//     "\n" + closer`; every existing byte is preserved. A file that already
//     declares top-level `inputs`/`outputs` of its own is refused (fail-open,
//     unchanged): the block defines both attributes, so injecting would
//     produce duplicate-attribute evaluation errors and break the file.
//   - empty/whitespace-only existing (no flake at all) → a fresh minimal
//     flake wrapping the block: "{\n" + block + "  };\n}\n" — the daemon's
//     create path. The block leaves the outputs return set open, so the
//     create scaffold closes it (`  };`) before closing the flake (`}`).
//
// ok is false — and existing is returned unchanged — when no safe injection
// point exists (no top-level `{ ... }` boundary) or the file already owns
// its inputs/outputs, so an unparseable or self-managing user file is never
// touched. Deterministic: same inputs produce the same bytes. The returned
// string is freshly allocated and owned by the caller.
patch_flake :: proc(existing, block: string) -> (string, bool) {
	if start, end, ok := find_nws_block(existing); ok {
		b := strings.builder_make(context.allocator)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, existing[:start])
		strings.write_string(&b, block)
		strings.write_string(&b, existing[end:])
		return strings.clone(strings.to_string(b), context.allocator), true
	}

	// Create path: an empty or whitespace-only file is not a flake to patch —
	// wrap the block in a minimal fresh top-level `{ ... }` scaffold so the
	// result is a valid flake.nix the user may then extend. The block carries
	// its own trailing newline after the END marker, so `}` lands on its own.
	if len(strings.trim_space(existing)) == 0 {
		// Create path: an empty or whitespace-only file is not a flake to
		// patch — wrap the block in a fresh minimal `{ ... }` scaffold. The
		// block leaves the return set open (END sits inside it), so the
		// scaffold appends the return set's closer `  };` before the flake's
		// `}`. The result is a valid flake.nix the user may then extend below
		// the END marker.
		b := strings.builder_make(context.allocator)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "{\n")
		strings.write_string(&b, block)
		strings.write_string(&b, "  };\n}\n")
		return strings.clone(strings.to_string(b), context.allocator), true
	}

	// Refuse to inject into a flake that already declares its own top-level
	// `inputs`/`outputs`: the block defines both, so injecting produces
	// duplicate-attribute errors ("attribute 'outputs' already defined") that
	// break evaluation. Such a file already manages its flake wiring itself
	// (e.g. a devenv flake); leave it alone — fail-open, never corrupt.
	if has_own_top_level_io(existing) {
		return existing, false
	}

	pos := last_top_level_brace(existing)
	if pos == -1 {
		return existing, false
	}
	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, existing[:pos])
	strings.write_string(&b, "\n")
	strings.write_string(&b, block)
	strings.write_string(&b, "\n")
	strings.write_string(&b, "\n")
	strings.write_string(&b, existing[pos:])
	return strings.clone(strings.to_string(b), context.allocator), true
}

// has_own_top_level_io reports whether text declares an `inputs` or
// `outputs` attribute of its own directly inside the flake's outer `{ ... }`
// shell (brace depth 1 — the level the nws block occupies). Both the
// attrset form (`inputs = { ... }`, `outputs = { self }: ...`) and the
// dotted form (`inputs.<name>.url = ...`) are recognised. Strings, comments,
// and the `${ ... }` contents of indented strings are skipped so prose or
// descriptions cannot trip it; anything ambiguous is treated as a hit — the
// caller refuses to inject (fail-open), which is always safe: the worst case
// is a file left alone, never a duplicate-attribute flake.
has_own_top_level_io :: proc(text: string) -> bool {
	depth := 0
	i := 0
	n := len(text)
	for i < n {
		c := text[i]
		switch {
		case c == '{':
			depth += 1
			i += 1
		case c == '}':
			if depth > 0 {
				depth -= 1
			}
			i += 1
		case c == '#':
			// Comment: skip to end of line.
			for i < n && text[i] != '\n' {
				i += 1
			}
		case c == '"':
			// Double-quoted string: skip to the closing quote, honouring
			// backslash escapes; an unterminated line bails conservatively.
			i += 1
			for i < n && text[i] != '\n' {
				if text[i] == '\\' {
					i += 2
				} else if text[i] == '"' {
					i += 1
					break
				} else {
					i += 1
				}
			}
		case c == '\'' && i + 1 < n && text[i + 1] == '\'':
			// Indented string: skip to the closing `''`.
			i += 2
			for i + 1 < n && !(text[i] == '\'' && text[i + 1] == '\'') {
				i += 1
			}
			i += 2
		case depth == 1 && ident_start_byte(c):
			j := i
			for j < n && ident_cont_byte(text[j]) {
				j += 1
			}
			if text[i:j] == "inputs" || text[i:j] == "outputs" {
				return true
			}
			i = j
		case:
			i += 1
		}
	}
	return false
}

// last_top_level_brace returns the byte offset of the last closing `}` at the
// top level of text — the one that closes the flake's outer scope — or -1
// when no such brace exists. Depth counts every brace (outer scope included);
// a top-level closer is exactly a `}` whose pre-decrement depth is 1, i.e.
// one that closes the scope opened by the very first `{`. Taking the last
// such brace means mid-file balanced attrset closes (which occur at depth >= 2)
// are never mistaken for the outer boundary, and a file that ends while the
// outer scope is still open (no top-level `}`) is reported as -1.
//
// Conservative by design: braces inside string literals or comments are
// counted like any other char, which can shift the decision on pathological
// input but never crashes — the caller refuses to patch when no brace is
// found, so a user file is never corrupted.
last_top_level_brace :: proc(text: string) -> int {
	last := -1
	depth := 0
	for pos: int = 0; pos < len(text); pos += 1 {
		switch text[pos] {
		case '{':
			depth += 1
		case '}':
			// pre-decrement depth 1: closes the outermost scope. The last one
			// wins, so in a well-formed file this is the final `}`.
			if depth == 1 {
				last = pos
			}
			if depth > 0 {
				depth -= 1
			}
		}
	}
	return last
}
