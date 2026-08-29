package core

import "core:strings"

// NWS_BLOCK_BEGIN marks the start of the region of a root flake owned by nws.
// A root flake containing a well-formed BEGIN…END pair is serviced in place:
// everything between the markers is nws's own output, everything outside is
// the user's and is never touched.
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
//   - block present in existing → the marked span is replaced by block
//     verbatim; user bytes outside the span are preserved.
//   - no block present → the block is injected before the last top-level
//     closing `}` (the flake's outer scope): `before + "\n" + block + "\n" +
//     "\n" + closer`; every existing byte is preserved.
//
// ok is false — and existing is returned unchanged — when no safe injection
// point exists (no top-level `{ ... }` boundary), so an unparseable user file
// is never touched. Deterministic: same inputs produce the same bytes. The
// returned string is freshly allocated and owned by the caller.
patch_flake :: proc(existing, block: string) -> (string, bool) {
	if start, end, ok := find_nws_block(existing); ok {
		b := strings.builder_make(context.allocator)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, existing[:start])
		strings.write_string(&b, block)
		strings.write_string(&b, existing[end:])
		return strings.clone(strings.to_string(b), context.allocator), true
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
