package tests

import "core:testing"
import "nwscore:core"

// Helper building an attr-name set for matcher tests.
attr_set :: proc(names: ..string) -> map[string]bool {
	m := make(map[string]bool)
	for n in names {
		m[n] = true
	}
	return m
}

@(test)
test_match_flat :: proc(t: ^testing.T) {
	names := attr_set("foo", "bar")
	defer delete(names)
	candidates := []string{"foo", "bar", "baz"}
	got := core.match_overlay_children(candidates, names)
	defer delete(got)
	testing.expectf(
		t,
		len(got) == 2 && got[0] == "bar" && got[1] == "foo",
		"expected sorted [bar, foo], got %v",
		got,
	)
}

@(test)
test_match_monorepo_deepest_wins :: proc(t: ^testing.T) {
	names := attr_set("repo", "sub")
	defer delete(names)
	candidates := []string{"other", "repo", "repo/sub", "repo/sub/src"}
	got := core.match_overlay_children(candidates, names)
	defer delete(got)
	testing.expectf(
		t,
		len(got) == 1 && got[0] == "repo/sub",
		"expected only deepest match repo/sub, got %v",
		got,
	)
}

@(test)
test_match_no_matches_empty :: proc(t: ^testing.T) {
	names := attr_set("qux")
	defer delete(names)
	candidates := []string{"foo", "bar/baz"}
	got := core.match_overlay_children(candidates, names)
	defer delete(got)
	testing.expectf(t, len(got) == 0, "expected empty result, got %v", got)
}

@(test)
test_match_empty_inputs :: proc(t: ^testing.T) {
	names := attr_set("x")
	defer delete(names)
	got := core.match_overlay_children([]string{}, names)
	defer delete(got)
	testing.expectf(t, len(got) == 0, "expected empty for no candidates, got %v", got)

	empty := make(map[string]bool)
	defer delete(empty)
	got2 := core.match_overlay_children([]string{"a"}, empty)
	defer delete(got2)
	testing.expectf(t, len(got2) == 0, "expected empty for no attr names, got %v", got2)
}

@(test)
test_match_sorting_deterministic :: proc(t: ^testing.T) {
	names := attr_set("b", "a", "c")
	defer delete(names)
	first := core.match_overlay_children([]string{"c", "a", "b"}, names)
	defer delete(first)
	second := core.match_overlay_children([]string{"b", "c", "a"}, names)
	defer delete(second)
	testing.expectf(t, len(first) == 3, "expected 3 matches, got %v", first)
	for i in 0 ..< len(first) {
		testing.expectf(
			t,
			first[i] == second[i],
			"output order not deterministic: %v vs %v",
			first,
			second,
		)
	}
	testing.expectf(
		t,
		first[0] == "a" && first[1] == "b" && first[2] == "c",
		"expected [a b c], got %v",
		first,
	)
}

@(test)
test_match_ancestor_out_of_order :: proc(t: ^testing.T) {
	// Robustness guard: even if an ancestor match appears *after* its
	// descendant in the candidate list (not produced by well-formed candidate
	// sets, but must not corrupt iteration), only the deepest survives.
	names := attr_set("repo", "sub")
	defer delete(names)
	candidates := []string{"repo/sub", "repo", "unrelated"}
	got := core.match_overlay_children(candidates, names)
	defer delete(got)
	testing.expectf(
		t,
		len(got) == 1 && got[0] == "repo/sub",
		"expected only repo/sub, got %v",
		got,
	)
}

@(test)
test_match_basename_only :: proc(t: ^testing.T) {
	// A candidate matches on its basename even when the full path differs
	// from the attribute name (monorepo case).
	names := attr_set("tf2_msgs")
	defer delete(names)
	candidates := []string{"ros/tf2_msgs", "ros/other"}
	got := core.match_overlay_children(candidates, names)
	defer delete(got)
	testing.expectf(
		t,
		len(got) == 1 && got[0] == "ros/tf2_msgs",
		"expected [ros/tf2_msgs], got %v",
		got,
	)
}
