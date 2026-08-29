package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// A well-formed block in the middle of surrounding text: the span covers the
// BEGIN line through the END line inclusive, with trailing newlines.
@(test)
test_find_nws_block_present :: proc(t: ^testing.T) {
	pre := "{\n  description = \"user\";\n}\n"
	body := "  inputs = { };\n"
	post := "# trailing comment\n"
	text := strings.concatenate(
		{pre, core.NWS_BLOCK_BEGIN, "\n", body, core.NWS_BLOCK_END, "\n", post},
	)
	defer delete(text)

	start, end, ok := core.find_nws_block(text)
	want_start := len(pre)
	want_end := len(pre) + len(core.NWS_BLOCK_BEGIN) + 1 + len(body) + len(core.NWS_BLOCK_END) + 1
	testing.expectf(t, ok, "well-formed block must be found")
	testing.expectf(t, start == want_start, "start=%d want=%d", start, want_start)
	testing.expectf(t, end == want_end, "end=%d want=%d", end, want_end)
	want_span := strings.concatenate({core.NWS_BLOCK_BEGIN, "\n", body, core.NWS_BLOCK_END, "\n"})
	defer delete(want_span)
	testing.expectf(t, text[start:end] == want_span, "span mismatch: %q", text[start:end])
}

// The last line of the text may omit its trailing newline; the span still
// covers the END line to the end of the text.
@(test)
test_find_nws_block_present_no_trailing_newline :: proc(t: ^testing.T) {
	text := core.NWS_BLOCK_BEGIN + "\nbody\n" + core.NWS_BLOCK_END
	start, end, ok := core.find_nws_block(text)
	testing.expectf(t, ok, "block without trailing newline must be found")
	testing.expectf(t, start == 0, "start=%d want=0", start)
	testing.expectf(t, end == len(text), "end=%d want=%d", end, len(text))
}

// Markers are matched on trimmed line content: indentation is allowed.
@(test)
test_find_nws_block_trims_indentation :: proc(t: ^testing.T) {
	text := "  " + core.NWS_BLOCK_BEGIN + "\n\tbody\n  " + core.NWS_BLOCK_END + "\n"
	start, end, ok := core.find_nws_block(text)
	// Matching is on the trimmed line content, but the span covers the whole
	// marker line, indentation included.
	testing.expectf(t, ok, "indented markers must be found")
	testing.expectf(t, start == 0, "start=%d want=0", start)
	testing.expectf(t, end == len(text), "end=%d want=%d", end, len(text))
}

// No markers anywhere: absent.
@(test)
test_find_nws_block_absent :: proc(t: ^testing.T) {
	text := "{\n  a = 1;\n}\n"
	start, end, ok := core.find_nws_block(text)
	testing.expectf(t, !ok, "absent block must not be found")
	testing.expectf(t, start == -1, "start must be -1, got %d", start)
	testing.expectf(t, end == -1, "end must be -1, got %d", end)
}

@(test)
test_find_nws_block_empty :: proc(t: ^testing.T) {
	_, _, ok := core.find_nws_block("")
	testing.expectf(t, !ok, "empty text has no block")
}

// Malformed: BEGIN without END.
@(test)
test_find_nws_block_begin_without_end :: proc(t: ^testing.T) {
	text := core.NWS_BLOCK_BEGIN + "\n{\n}\n"
	_, _, ok := core.find_nws_block(text)
	testing.expectf(t, !ok, "BEGIN without END must fail")
}

// Malformed: END without BEGIN (out of order).
@(test)
test_find_nws_block_end_without_begin :: proc(t: ^testing.T) {
	text := core.NWS_BLOCK_END + "\n{\n}\n"
	_, _, ok := core.find_nws_block(text)
	testing.expectf(t, !ok, "END without BEGIN must fail")
}

// Duplicate BEGIN before any END is ambiguous → fail open, never corrupt.
@(test)
test_find_nws_block_duplicate_begin :: proc(t: ^testing.T) {
	text := core.NWS_BLOCK_BEGIN + "\n" + core.NWS_BLOCK_BEGIN + "\n" + core.NWS_BLOCK_END + "\n"
	_, _, ok := core.find_nws_block(text)
	testing.expectf(t, !ok, "second BEGIN before END must fail")
}

// An extra END after a well-formed pair is inert text outside the span.
@(test)
test_find_nws_block_duplicate_end :: proc(t: ^testing.T) {
	text :=
		core.NWS_BLOCK_BEGIN + "\nbody\n" + core.NWS_BLOCK_END + "\n" + core.NWS_BLOCK_END + "\n"
	start, end, ok := core.find_nws_block(text)
	testing.expectf(t, ok, "block with a trailing END must still be found")
	testing.expectf(
		t,
		strings.count(text[start:end], core.NWS_BLOCK_END) == 1,
		"span must end at the first END",
	)
}

@(test)
test_has_nws_block :: proc(t: ^testing.T) {
	has := core.NWS_BLOCK_BEGIN + "\nbody\n" + core.NWS_BLOCK_END + "\n"
	testing.expectf(t, core.has_nws_block(has), "well-formed block detected")
	testing.expectf(t, !core.has_nws_block("{\n}\n"), "plain flake has no block")
	testing.expectf(t, !core.has_nws_block(core.NWS_BLOCK_BEGIN), "BEGIN alone is not a block")
	testing.expectf(t, !core.has_nws_block(""), "empty text has no block")
}

// Injecting into a user flake: every existing byte is preserved and the block
// lands before the final top-level closing `}`.
@(test)
test_patch_flake_inject :: proc(t: ^testing.T) {
	user := "{\n  description = \"my flake\";\n  inputs = { nixpkgs.url = \"github:nixos/nixpkgs\"; };\n  outputs = { self, nixpkgs }: { packages.x86_64-linux.hello = nixpkgs.hello; };\n}\n"
	block := core.NWS_BLOCK_BEGIN + "\n  inputs = { };\n" + core.NWS_BLOCK_END + "\n"

	got, ok := core.patch_flake(user, block)
	defer delete(got)
	testing.expectf(t, ok, "inject must succeed")

	want := strings.concatenate(
		{
			"{\n  description = \"my flake\";\n  inputs = { nixpkgs.url = \"github:nixos/nixpkgs\"; };\n  outputs = { self, nixpkgs }: { packages.x86_64-linux.hello = nixpkgs.hello; };\n",
			"\n",
			block,
			"\n",
			"\n",
			"}\n",
		},
	)
	defer delete(want)
	testing.expectf(
		t,
		got == want,
		"inject mismatch:\n--- got ---\n%s\n--- want ---\n%s",
		got,
		want,
	)
	testing.expectf(
		t,
		strings.contains(got, "description = \"my flake\";"),
		"user content must survive",
	)
}

// Updating an existing block: only the marked region is replaced; user bytes
// before and after are preserved verbatim.
@(test)
test_patch_flake_update :: proc(t: ^testing.T) {
	pre := "{\n  description = \"user flake\";\n"
	old_block := core.NWS_BLOCK_BEGIN + "\n  inputs = { old = 1; };\n" + core.NWS_BLOCK_END + "\n"
	post := "  outputs = { self }: { };\n}\n"
	existing := strings.concatenate({pre, old_block, post})
	defer delete(existing)

	new_block := core.NWS_BLOCK_BEGIN + "\n  inputs = { new = 2; };\n" + core.NWS_BLOCK_END + "\n"
	got, ok := core.patch_flake(existing, new_block)
	defer delete(got)
	testing.expectf(t, ok, "update must succeed")

	want := strings.concatenate({pre, new_block, post})
	defer delete(want)
	testing.expectf(
		t,
		got == want,
		"update mismatch:\n--- got ---\n%s\n--- want ---\n%s",
		got,
		want,
	)
	testing.expectf(t, !strings.contains(got, "old = 1"), "old block body must be replaced")
	testing.expectf(
		t,
		strings.contains(got, "description = \"user flake\";"),
		"pre-block user bytes lost",
	)
	testing.expectf(
		t,
		strings.contains(got, "outputs = { self }: { };"),
		"post-block user bytes lost",
	)
}

// Unparseable text (no top-level `{ ... }` boundary) → unchanged + false.
// (The empty/whitespace-only case is the CREATE path — see
// test_patch_flake_create.)
@(test)
test_patch_flake_unparseable :: proc(t: ^testing.T) {
	block := core.NWS_BLOCK_BEGIN + "\n" + core.NWS_BLOCK_END + "\n"
	cases := []string {
		"no braces at all\n",
		"nixpkgs.url = \"github:nixos/nixpkgs\";\n",
		"{\n  inputs = { };\n", // opener without a top-level closer
		"just a stray } without an opener\n",
	}
	for text in cases {
		got, ok := core.patch_flake(text, block)
		testing.expectf(t, !ok, "must refuse to patch %q", text)
		testing.expectf(t, got == text, "unparseable text must be returned unchanged, got %q", got)
	}
}

// An empty block (BEGIN/END with no body) is still a valid block: it injects,
// and updating an identical block is a byte no-op (deterministic round-trip).
@(test)
test_patch_flake_empty_block :: proc(t: ^testing.T) {
	user := "{\n  a = 1;\n}\n"
	empty_block := core.NWS_BLOCK_BEGIN + "\n" + core.NWS_BLOCK_END + "\n"

	got, ok := core.patch_flake(user, empty_block)
	defer delete(got)
	testing.expectf(t, ok, "empty block must inject")
	testing.expectf(t, strings.contains(got, core.NWS_BLOCK_BEGIN), "BEGIN missing")
	testing.expectf(t, strings.contains(got, core.NWS_BLOCK_END), "END missing")
	testing.expectf(t, strings.contains(got, "a = 1;"), "user content must survive")

	again, ok2 := core.patch_flake(got, empty_block)
	defer delete(again)
	testing.expectf(t, ok2, "empty-block update must succeed")
	testing.expectf(t, again == got, "identical block update must be a byte no-op")
}

// Create path: an empty or whitespace-only existing file is not a flake to
// patch — patch_flake wraps the block in a fresh minimal `{ ... }` scaffold
// (the daemon's no-flake path). The result must round-trip: repatching with
// the same block is a byte no-op, which is what prevents the self-trigger
// loop on a freshly created file.
@(test)
test_patch_flake_create :: proc(t: ^testing.T) {
	block := core.NWS_BLOCK_BEGIN + "\n  inputs = { };\n" + core.NWS_BLOCK_END + "\n"
	want := strings.concatenate({"{\n", block, "}\n"})
	defer delete(want)

	inputs := []string{"", "  \n\t\n", "\n\n"}
	for text in inputs {
		got, ok := core.patch_flake(text, block)
		defer delete(got)
		testing.expectf(t, ok, "create must succeed for %q", text)
		testing.expectf(
			t,
			got == want,
			"create mismatch for %q:\n--- got ---\n%s\n--- want ---\n%s",
			text,
			got,
			want,
		)
		testing.expectf(t, strings.contains(got, block), "block must be preserved verbatim")

		roundtrip, ok2 := core.patch_flake(got, block)
		defer delete(roundtrip)
		testing.expectf(t, ok2, "round-trip update must succeed")
		testing.expectf(
			t,
			roundtrip == got,
			"created flake must be patch-stable (loop guard)\n--- got ---\n%s\n--- twice ---\n%s",
			got,
			roundtrip,
		)
	}
}

// Daemon lifecycle (T3): an absent flake is created wrapping the block; a
// user devShell added outside the markers survives regeneration while the
// block updates in place; repatching is a byte no-op (loop guard).
@(test)
test_patch_flake_daemon_lifecycle :: proc(t: ^testing.T) {
	block_v1 := core.NWS_BLOCK_BEGIN + "\n  inputs = { };\n" + core.NWS_BLOCK_END + "\n"

	// 1. Create path — no flake yet.
	created, ok1 := core.patch_flake("", block_v1)
	defer delete(created)
	testing.expectf(t, ok1, "create must succeed")
	testing.expectf(
		t,
		strings.has_prefix(created, "{\n" + core.NWS_BLOCK_BEGIN + "\n"),
		"created flake must wrap the block",
	)
	testing.expectf(t, strings.has_suffix(created, "}\n"), "created flake must close braces")

	// 2. User adds a devShell between the block and the closing brace.
	user_flake := strings.concatenate(
		{"{\n", block_v1, "  devShells.x86_64-linux.default = pkgs.mkShell { };\n}\n"},
	)
	defer delete(user_flake)

	// 3. Regeneration with a changed block — the user devShell must survive.
	block_v2 :=
		core.NWS_BLOCK_BEGIN +
		"\n  inputs = { nixpkgs.url = \"github:nixos/nixpkgs\"; };\n" +
		core.NWS_BLOCK_END +
		"\n"
	patched, ok2 := core.patch_flake(user_flake, block_v2)
	defer delete(patched)
	testing.expectf(t, ok2, "update must succeed")
	testing.expectf(t, strings.contains(patched, block_v2), "block must update to v2")
	testing.expectf(
		t,
		strings.contains(patched, "devShells.x86_64-linux.default = pkgs.mkShell { };"),
		"user devShell must survive regeneration",
	)
	testing.expectf(
		t,
		strings.count(patched, core.NWS_BLOCK_BEGIN) == 1,
		"exactly one nws block must remain",
	)

	// 4. Loop guard: repatching with the same block is a byte no-op.
	again, ok3 := core.patch_flake(patched, block_v2)
	defer delete(again)
	testing.expectf(t, ok3, "idempotent update must succeed")
	testing.expectf(t, again == patched, "identical patch must be a byte no-op")
}

// Determinism: patching the same inputs twice yields the same bytes.
@(test)
test_patch_flake_deterministic :: proc(t: ^testing.T) {
	user := "{\n  a = 1;\n}\n"
	block_a := core.NWS_BLOCK_BEGIN + "\n  x = 1;\n" + core.NWS_BLOCK_END + "\n"
	block_b := core.NWS_BLOCK_BEGIN + "\n  y = 2;\n" + core.NWS_BLOCK_END + "\n"

	first, ok1 := core.patch_flake(user, block_a)
	defer delete(first)
	second, ok2 := core.patch_flake(user, block_a)
	defer delete(second)
	testing.expectf(t, ok1 && ok2, "inject must succeed")
	testing.expectf(t, first == second, "patch_flake is not deterministic")

	// A different block body lands in the same spot and updates cleanly.
	updated, ok3 := core.patch_flake(first, block_b)
	defer delete(updated)
	testing.expectf(t, ok3, "update must succeed")
	testing.expectf(t, strings.contains(updated, "y = 2;"), "new body missing")
	testing.expectf(t, !strings.contains(updated, "x = 1;"), "old body must be replaced")
	testing.expectf(t, strings.contains(updated, "a = 1;"), "user content must survive")
}

// A malformed (dangling) BEGIN is treated as "no block": the file is patched
// by injection and the pre-existing marker line survives as user content.
@(test)
test_patch_flake_malformed_block_injects :: proc(t: ^testing.T) {
	user := core.NWS_BLOCK_BEGIN + "\nleft half\n{\n  a = 1;\n}\n"
	block := core.NWS_BLOCK_BEGIN + "\n" + core.NWS_BLOCK_END + "\n"

	got, ok := core.patch_flake(user, block)
	defer delete(got)
	testing.expectf(t, ok, "malformed block must fall back to injection")
	testing.expectf(
		t,
		strings.has_prefix(got, core.NWS_BLOCK_BEGIN + "\nleft half\n"),
		"pre-existing marker line must survive as user bytes",
	)
	testing.expectf(
		t,
		strings.count(got, core.NWS_BLOCK_BEGIN) == 2,
		"user's dangling BEGIN must survive alongside the fresh block",
	)
}
