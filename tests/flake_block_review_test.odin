package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// structural_balance counts '{' minus '}' over CODE tokens only (scan_tokens
// skips strings/comments), so it reports real brace balance even when the
// text contains braces inside literals — unlike core.count_braces, which is
// naïve. A well-formed injected flake is balanced.
structural_balance :: proc(t: ^testing.T, s: string) -> int {
	toks := core.scan_tokens(s, context.allocator)
	defer delete(toks)
	depth := 0
	for tok in toks {
		if tok.kind != .Code {
			continue
		}
		for i := tok.start; i < tok.end; i += 1 {
			switch s[i] {
			case '{':
				depth += 1
			case '}':
				depth -= 1
			}
		}
	}
	return depth
}

// P0 regression: every generator block leaves the outputs return set OPEN at
// its END marker — the inject path must close that set with `  };` before the
// file's own final `}` (exactly like the create scaffold), or the result is
// an unparseable flake with the outer `{ ... }` left unclosed. Injecting a
// REAL generate_overlay_block / generate_root_block into a user fixture must
// produce a structurally balanced flake ending in `  };\n}\n` — never the
// old broken shape. This test failed before the P0 fix (braces unbalanced,
// suffix missing).
@(test)
test_patch_flake_inject_real_block :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child {
		{name = "tf2_msgs", rel_path = "ros/tf2_msgs"},
		{name = "tf2", rel_path = "tf2"},
	}
	block := core.generate_overlay_block(children, cfg)
	defer delete(block)

	user := "{\n  description = \"user flake\";\n}\n"
	got, ok := core.patch_flake(user, block)
	defer delete(got)
	testing.expectf(t, ok, "inject of a real overlay block must succeed")
	testing.expectf(
		t,
		structural_balance(t, got) == 0,
		"injected flake must be brace-balanced:\n%s",
		got,
	)
	testing.expectf(
		t,
		strings.has_suffix(got, "  };\n}\n"),
		"inject must close the return set (`  };`) before the file's `}`:\n%s",
		got,
	)
	testing.expectf(t, strings.contains(got, "description = \"user flake\";"), "user bytes lost")
	testing.expectf(t, strings.contains(got, core.NWS_BLOCK_BEGIN), "BEGIN marker missing")

	// Same guarantee for the flake-delegation (root) backend.
	root_block := core.generate_root_block(
		[]core.Child_Info{{name = "alpha", url = "x", has_url = true}},
	)
	defer delete(root_block)
	got2, ok2 := core.patch_flake(user, root_block)
	defer delete(got2)
	testing.expectf(t, ok2, "inject of a real root block must succeed")
	testing.expectf(
		t,
		structural_balance(t, got2) == 0,
		"root injection must be balanced:\n%s",
		got2,
	)
	testing.expectf(
		t,
		strings.has_suffix(got2, "  };\n}\n"),
		"root inject must close the return set",
	)

	// Update path on an injected file: replacing [BEGIN, END) with a changed
	// block keeps the user's `  };`/`}` closers and stays balanced. The on-disc
	// create/inject outputs always carry those closers after END, so the
	// update path (which only rewrites the marked span) remains correct for
	// all three creation routes.
	cfg2 := ros_cfg()
	defer core.delete_workspace_config(cfg2)
	children2 := []core.Overlay_Child{{name = "extra", rel_path = "extra"}}
	block2 := core.generate_overlay_block(children2, cfg2)
	defer delete(block2)
	got3, ok3 := core.patch_flake(got, block2)
	defer delete(got3)
	testing.expectf(t, ok3, "update of an injected flake must succeed")
	testing.expectf(
		t,
		structural_balance(t, got3) == 0,
		"updated flake must be balanced:\n%s",
		got3,
	)
	testing.expectf(
		t,
		strings.has_suffix(got3, "  };\n}\n"),
		"update must preserve the user closers",
	)
	testing.expectf(t, strings.contains(got3, "extra"), "new block body must be present")
	testing.expectf(
		t,
		strings.count(got3, core.NWS_BLOCK_BEGIN) == 1,
		"exactly one block must remain",
	)
}

// P1: last_top_level_brace must choose the STRUCTURAL closer. Braces inside
// strings, indented strings and comments are inert — a `}` inside a literal
// at depth 1 must never be picked as the injection point (the old naive scan
// did, injecting the block inside the literal).
@(test)
test_last_top_level_brace_skips_literals :: proc(t: ^testing.T) {
	cases := []struct {
		name, text: string,
	} {
		{"string", "{\n  desc = \"x } y\";\n}\n"},
		{"interp", "{\n  desc = \"a } ${ b } c\";\n}\n"},
		{"indented", "{\n  desc = '' x } y '';\n}\n"},
		{"comment", "{\n  # a } comment\n  a = 1;\n}\n"},
	}
	for c in cases {
		pos := core.last_top_level_brace(c.text)
		want := strings.last_index(c.text, "}")
		testing.expectf(
			t,
			pos == want,
			"[%s] injection point pos=%d want=%d (must be the structural closer):\n%s",
			c.name,
			pos,
			want,
			c.text,
		)
	}
}

// P1 integration: patch_flake injects a REAL generator block into fixtures
// whose `}` could be confused with literals; the block must land after the
// literal and before the structural closer, leaving a valid flake.
@(test)
test_patch_flake_inject_literal_braces :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child{{name = "alpha", rel_path = "alpha"}}
	block := core.generate_overlay_block(children, cfg)
	defer delete(block)

	// [0]=fixture, [1]=literal text that must precede the injected block.
	cases := [][2]string {
		{"{\n  desc = \"x } y\";\n}\n", `desc = "x } y";`},
		{"{\n  desc = '' x } y '';\n}\n", "'' x } y ''"},
		{"{\n  # a } comment\n  a = 1;\n}\n", "# a } comment"},
	}
	for c, i in cases {
		user := c[0]
		lit := c[1]
		got, ok := core.patch_flake(user, block)
		defer delete(got)
		testing.expectf(t, ok, "case %d: inject must succeed", i)
		block_at := strings.index(got, core.NWS_BLOCK_BEGIN)
		lit_at := strings.index(got, lit)
		testing.expectf(
			t,
			lit_at >= 0 && block_at > lit_at + len(lit),
			"case %d: block must land after the literal (lit_at=%d block_at=%d):\n%s",
			i,
			lit_at,
			block_at,
			got,
		)
		testing.expectf(
			t,
			strings.has_suffix(got, "  };\n}\n"),
			"case %d: return-set closer + flake closer must end the file:\n%s",
			i,
			got,
		)
		depth := structural_balance(t, got)
		testing.expectf(
			t,
			depth == 0,
			"case %d: structural braces must balance (%d):\n%s",
			i,
			depth,
			got,
		)
	}
}

// P2b: quoted attr keys like `"inputs" = ...` are string content to the
// lexer. Only UNQUOTED `inputs`/`outputs` identifiers at top level count as
// the block collision (the refusal case, covered by
// test_patch_flake_refuse_own_io); quoted ones must NOT trip the refusal.
@(test)
test_patch_flake_quoted_io_keys_not_refused :: proc(t: ^testing.T) {
	block := core.NWS_BLOCK_BEGIN + "\n  inputs = { };\n" + core.NWS_BLOCK_END + "\n"
	cases := []string {
		"{\n  \"inputs\" = { a = 1; };\n}\n",
		"{\n  \"outputs\" = { self }: { };\n}\n",
	}
	for text in cases {
		got, ok := core.patch_flake(text, block)
		defer delete(got)
		testing.expectf(t, ok, "quoted key must not be refused: %q", text)
		testing.expectf(
			t,
			strings.contains(got, core.NWS_BLOCK_BEGIN),
			"block must inject into %q",
			text,
		)
	}
}

// P2a: patch_refusal_reason produces the clear, actionable warning the daemon
// logs when a flake is refused — naming the inputs/outputs conflict, and the
// legacy `# nws-generated` migration path, instead of the generic message.
@(test)
test_patch_refusal_reason :: proc(t: ^testing.T) {
	own_io := "{\n  inputs = { };\n}\n"
	legacy := "# nws-generated — do not edit\n{\n  inputs = { };\n  outputs = { self }: { };\n}\n"
	unparseable := "no braces here\n"

	msg := core.patch_refusal_reason(own_io)
	testing.expectf(
		t,
		strings.contains(msg, "inputs/outputs"),
		"own-io message must name the conflict: %q",
		msg,
	)
	legacy_msg := core.patch_refusal_reason(legacy)
	testing.expectf(
		t,
		strings.contains(legacy_msg, "nws-generated"),
		"legacy message must point at the migration path: %q",
		legacy_msg,
	)
	gen_msg := core.patch_refusal_reason(unparseable)
	testing.expectf(
		t,
		strings.contains(gen_msg, "no safe injection point"),
		"generic message expected: %q",
		gen_msg,
	)
}

// P3: the create and inject paths must not assume the block ends with '\n'.
// A caller-supplied block missing the trailing newline after the END marker
// is normalised so the return-set closer and the flake's `}` still land on
// their own lines.
@(test)
test_patch_flake_block_without_trailing_newline :: proc(t: ^testing.T) {
	block := core.NWS_BLOCK_BEGIN + "\n  x = 1;\n" + core.NWS_BLOCK_END // no trailing '\n'
	user := "{\n  a = 1;\n}\n"

	created, ok := core.patch_flake("", block)
	defer delete(created)
	testing.expectf(t, ok, "create must succeed")
	testing.expectf(
		t,
		strings.has_suffix(created, "  };\n}\n") &&
		strings.contains(created, core.NWS_BLOCK_END + "\n  };\n"),
		"create must separate END from the closer:\n%s",
		created,
	)

	got, ok2 := core.patch_flake(user, block)
	defer delete(got)
	testing.expectf(t, ok2, "inject must succeed")
	testing.expectf(
		t,
		strings.has_suffix(got, "  };\n}\n") &&
		strings.contains(got, core.NWS_BLOCK_END + "\n  };\n"),
		"inject must separate END from the closer:\n%s",
		got,
	)
}
