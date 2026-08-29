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

// NWS_DEVSHELL_BLOCK_BEGIN/END mark a nested managed region INSIDE a user's
// own devShell definition (typically inside its `let`). When a workspace
// enables the managed devShell (dev_shell_packages non-empty) and these
// markers are present, nws fills the span with the `env = spliced0.buildEnv
// {...}` binding (children first, then the configured extras) so the user's
// devShell just writes `packages = [ env ];` — the standard nix-ros-overlay
// shape. The main nws block must NOT also emit devShells.<system>.default in
// this case (duplicate attr); presence of the markers suppresses emission.
NWS_DEVSHELL_BLOCK_BEGIN :: "# nws devShell block — managed by nws; do not edit"

// NWS_DEVSHELL_BLOCK_END marks the end of the nested devShell region.
NWS_DEVSHELL_BLOCK_END :: "# /nws devShell block"

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

// find_devshell_block locates the first well-formed nested devShell block in
// text: the first line whose trimmed content equals NWS_DEVSHELL_BLOCK_BEGIN,
// then the next line whose trimmed content equals NWS_DEVSHELL_BLOCK_END. The
// returned byte span [start, end) covers the BEGIN line through the END line
// inclusive, each including its trailing newline when present. ok is false —
// and start/end are both -1 — for missing or malformed/duplicated markers
// (fail-open, never corrupt).
find_devshell_block :: proc(text: string) -> (start, end: int, ok: bool) {
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
			if t == NWS_DEVSHELL_BLOCK_BEGIN {
				begin_off = i
			}
		} else {
			if t == NWS_DEVSHELL_BLOCK_BEGIN {
				return // duplicated BEGIN — ambiguous, fail open
			}
			if t == NWS_DEVSHELL_BLOCK_END {
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

// patch_devshell_block replaces the marked devShell region (BEGIN line through
// END line inclusive) of existing with block — where block is expected to
// carry its own BEGIN and END marker lines around the generated binding. When
// no well-formed region exists, existing is returned unchanged (fail-open).
patch_devshell_block :: proc(existing, block: string) -> (string, bool) {
	start, end, ok := find_devshell_block(existing)
	if !ok {
		return existing, false
	}
	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, existing[:start])
	strings.write_string(&b, block)
	strings.write_string(&b, existing[end:])
	return strings.clone(strings.to_string(b), context.allocator), true
}

// user_zone_has_devshell reports whether text declares a devShell ANYWHERE
// outside the nws-managed block span (any system attr — the nws block itself
// may legitimately contain `devShells.<system>.default` when nws emits it).
// The check is literal-aware (scan_tokens): only the identifier `devShells`
// as a code token counts, so prose/strings mentioning it cannot trip the
// guard. When the user already owns a devShell, nws must NOT emit its own
// top-level devShell (duplicate-attribute eval errors); it either fills the
// user's nested devShell block (when the markers are present) or leaves the
// user's content alone (fail-open).
user_zone_has_devshell :: proc(text: string) -> bool {
	nw_start, nw_end, has_block := find_nws_block(text)
	if has_block && user_zone_has_devshell_span(text, 0, nw_start) {
		return true
	}
	if has_block && user_zone_has_devshell_span(text, nw_end, len(text)) {
		return true
	}
	if !has_block {
		return user_zone_has_devshell_span(text, 0, len(text))
	}
	return false
}

// user_zone_has_devshell_span scans [start, end) of text for the code-token
// identifier `devShells` (word-bounded).
user_zone_has_devshell_span :: proc(text: string, start, end: int) -> bool {
	tokens := scan_tokens(text, context.allocator)
	defer delete(tokens)
	for tok in tokens {
		if tok.kind != .Code {
			continue
		}
		if tok.start >= end || tok.end <= start {
			continue
		}
		a := max(tok.start, start)
		z := min(tok.end, end)
		for i := a; i < z; i += 1 {
			if strings.has_prefix(text[i:z], "devShells") {
				before_ok := i == a || !ident_cont_byte(text[i - 1])
				after := i + len("devShells")
				after_ok := after >= z || !ident_cont_byte(text[after])
				if before_ok && after_ok {
					return true
				}
			}
		}
	}
	return false
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
//     closing `}` (the flake's outer scope), first closing the outputs return
//     set the block leaves open at its END marker with `  };` (mirroring the
//     create scaffold): `before + "\n" + block + "  };\n" + closer`. Every
//     existing byte is preserved. A file that already
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
		block_normalized := normalize_block_end(block)
		defer delete(block_normalized)
		b := strings.builder_make(context.allocator)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "{\n")
		strings.write_string(&b, block_normalized)
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
	// The block leaves the outputs return set open at its END marker (see the
	// file-top contract), so before the file's own final `}` we additionally
	// emit the return set's closer `  };` — exactly what the create scaffold
	// does. The file's `}` then closes the outer scope, so the result is
	// `before + block + "  };\n" + closer`, brace-balanced for every
	// generator block. Without the closer, the file's `}` would collapse the
	// return set and leave the file's own outer `{ ... }` unclosed
	// (unparseable).
	block_normalized := normalize_block_end(block)
	defer delete(block_normalized)

	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, existing[:pos])
	strings.write_string(&b, "\n")
	strings.write_string(&b, block_normalized)
	strings.write_string(&b, "  };\n")
	strings.write_string(&b, existing[pos:])
	return strings.clone(strings.to_string(b), context.allocator), true
}

// normalize_block_end returns a copy of block guaranteed to end in exactly
// one '\n' (trailing '\r'/'\n' runs collapsed), so the return-set closer and
// the flake's closing brace always land on their own lines regardless of how
// the caller formed the block. Generator output already has this shape (END
// marker + '\n'); the normalisation only hardens the create/inject paths'
// layout guarantee. The returned string is allocated from allocator and
// owned by the caller.
normalize_block_end :: proc(block: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_right(block, "\r\n")
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, trimmed)
	strings.write_string(&b, "\n")
	return strings.clone(strings.to_string(b), allocator)
}

// has_own_top_level_io reports whether text declares an `inputs` or
// `outputs` attribute of its own directly inside the flake's outer `{ ... }`
// shell (brace depth 1 — the level the nws block occupies). Both the
// attrset form (`inputs = { ... }`, `outputs = { self }: ...`) and the
// dotted form (`inputs.<name>.url = ...`) are recognised. Scanning is
// literal-aware (see scan_tokens): braces and identifiers inside strings,
// indented strings and comments are inert, so prose cannot trip it. Only
// UNQUOTED `inputs`/`outputs` identifiers count as the collision — a quoted
// key like `"inputs" = ...` is string content, not a declaration the lexer
// matches. Anything ambiguous is treated as a hit — the caller refuses to
// inject (fail-open), which is always safe: the worst case is a file left
// alone, never a duplicate-attribute flake.
has_own_top_level_io :: proc(text: string) -> bool {
	tokens := scan_tokens(text, context.allocator)
	defer delete(tokens)
	depth := 0
	for tok in tokens {
		if tok.kind != .Code {
			continue
		}
		for i := tok.start; i < tok.end; {
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
			case depth == 1 && ident_start_byte(c):
				j := i
				for j < tok.end && ident_cont_byte(text[j]) {
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
	}
	return false
}

// scan_tokens splits text into runs of CODE (unlexed Nix source) and LITERAL
// content (double-quoted strings, indented strings, `#` comments). Only CODE
// carries structure: braces and identifiers inside literal runs are inert.
// Literal rules match Nix closely enough for flake.nix anatomy:
//
//   - `#` … end of line        → comment;
//   - `"` … next unescaped `"` → double-quoted string;
//   - `''` … next `''`         → indented string;
//   - anything else            → code.
//
// `${ ... }` interpolation inside strings is skipped wholesale with the
// string, so a `}` inside it can never be mistaken for structure. An
// unterminated literal is consumed to the end of its line — conservative:
// its braces stay inert, which never crashes and only ever errs toward a
// refusal to patch. The returned slice is allocated from allocator and owned
// by the caller.
scan_tokens :: proc(text: string, allocator := context.allocator) -> [dynamic]Scan_Token {
	tokens := make([dynamic]Scan_Token, 0, 16, allocator)
	i := 0
	n := len(text)
	code_start := 0
	for i < n {
		c := text[i]
		switch {
		case c == '#':
			if code_start < i {
				append(&tokens, Scan_Token{start = code_start, end = i, kind = .Code})
			}
			j := i
			for j < n && text[j] != '\n' {
				j += 1
			}
			append(&tokens, Scan_Token{start = i, end = j, kind = .Comment})
			i = j
			code_start = i
		case c == '"':
			if code_start < i {
				append(&tokens, Scan_Token{start = code_start, end = i, kind = .Code})
			}
			start := i
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
			append(&tokens, Scan_Token{start = start, end = i, kind = .String})
			code_start = i
		case c == '\'' && i + 1 < n && text[i + 1] == '\'':
			if code_start < i {
				append(&tokens, Scan_Token{start = code_start, end = i, kind = .Code})
			}
			start := i
			i += 2
			for i + 1 < n && !(text[i] == '\'' && text[i + 1] == '\'') {
				i += 1
			}
			// i sits on the first `''` of a closing pair when one exists, else
			// at the last byte of an unterminated string; consume the pair.
			if i + 1 < n {
				i += 2
			} else {
				i = n
			}
			append(&tokens, Scan_Token{start = start, end = i, kind = .Indented})
			code_start = i
		case:
			i += 1
		}
	}
	if code_start < i {
		append(&tokens, Scan_Token{start = code_start, end = i, kind = .Code})
	}
	return tokens
}

// Scan_Kind classifies a token run: Code is structurally significant Nix
// source; String, Indented and Comment are literal content whose braces never
// count as structure.
Scan_Kind :: enum {
	Code,
	String,
	Indented,
	Comment,
}

// Scan_Token is one run of Scan_Kind over the byte span [start, end) of the
// scanned text.
Scan_Token :: struct {
	kind:       Scan_Kind,
	start, end: int,
}

// LEGACY_NWS_GENERATED_HEADER is the header line the pre-block nws backend
// (v1) wrote above every root flake it managed wholesale. It is used for
// diagnostics only: such a file is serviced normally unless it also declares
// its own top-level inputs/outputs (see has_own_top_level_io).
LEGACY_NWS_GENERATED_HEADER :: "# nws-generated"

// patch_refusal_reason explains why patch_flake would refuse to manage text
// (fail-open), with an actionable remedy, so the daemon can log a clear
// warning instead of silently leaving a workspace unmanaged. A file declaring
// its own top-level `inputs`/`outputs` — including a legacy v1 flake with
// the old `# nws-generated` header — gets a targeted message naming the
// conflict and the remedy; any other refusal gets the generic
// no-safe-injection-point message. The returned string is a static literal.
patch_refusal_reason :: proc(text: string) -> string {
	if has_own_top_level_io(text) {
		if strings.contains(text, LEGACY_NWS_GENERATED_HEADER) {
			return(
				"flake was generated by an older nws (# nws-generated) and declares its own top-level inputs/outputs, which conflict with the nws block — delete the file (or remove its own inputs/outputs) to let nws regenerate it, or it stays unmanaged" \
			)
		}
		return(
			"flake declares its own top-level inputs/outputs, which conflict with the nws block — remove them to let nws manage it, or it stays unmanaged" \
		)
	}
	return "no safe injection point (no top-level { ... } boundary)"
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
// Literal-aware (via scan_tokens): braces inside strings, indented strings
// and comments are not counted, so a placeholder or comment whose text
// contains `}` cannot shift the depth and mislead the injection point — the
// block never lands inside a literal. The caller still refuses to patch when
// no brace is found, so a user file is never corrupted.
last_top_level_brace :: proc(text: string) -> int {
	tokens := scan_tokens(text, context.allocator)
	defer delete(tokens)
	last := -1
	depth := 0
	for tok in tokens {
		if tok.kind != .Code {
			continue
		}
		for pos := tok.start; pos < tok.end; pos += 1 {
			switch text[pos] {
			case '{':
				depth += 1
			case '}':
				// Pre-decrement depth 1: closes the outermost scope. The last
				// one wins, so in a well-formed file this is the final `}`.
				if depth == 1 {
					last = pos
				}
				if depth > 0 {
					depth -= 1
				}
			}
		}
	}
	return last
}
