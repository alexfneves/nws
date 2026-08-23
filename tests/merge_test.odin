package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// ---- merge_children: union / dedup / resolver-wins / sort ----
//
// The inputs borrow plain string literals (the test does not own them and the
// merge must not free them); the returned children own fresh strings plus the
// backing slice, which the test frees.

// free_children frees the owned name/rel_path strings plus the backing array
// of one merge result.
free_merge_children :: proc(ch: []core.Overlay_Child) {
	for c in ch {
		delete(c.name)
		delete(c.rel_path)
	}
	delete(ch)
}

// free_warn frees a merge warning when it is a heap string ("" is not).
free_merge_warn :: proc(w: string) {
	if len(w) > 0 {
		delete(w)
	}
}

@(test)
test_merge_union_dedup_by_rel_path :: proc(t: ^testing.T) {
	builtin := []core.Overlay_Child {
		core.Overlay_Child{name = "pkg", rel_path = "pkg"},
		core.Overlay_Child{name = "ros", rel_path = "ros/humble"},
	}
	resolver := []core.Overlay_Child {
		core.Overlay_Child{name = "pkg", rel_path = "pkg"}, // same rel_path as builtin
	}
	got, warn := core.merge_children(builtin, resolver)
	defer free_merge_children(got)
	defer free_merge_warn(warn)
	// Same rel_path + same name -> dedup (first occurrence wins), no conflict.
	testing.expectf(t, len(got) == 2, "expected 2 children, got %v", len(got))
	testing.expectf(
		t,
		got[0].name == "pkg" && got[0].rel_path == "pkg",
		"got %q/%q",
		got[0].name,
		got[0].rel_path,
	)
	testing.expectf(
		t,
		got[1].name == "ros" && got[1].rel_path == "ros/humble",
		"got %q/%q",
		got[1].name,
		got[1].rel_path,
	)
	testing.expectf(t, len(warn) == 0, "unexpected warning %q", warn)
}

@(test)
test_merge_first_occurrence_wins_on_rel :: proc(t: ^testing.T) {
	// Same directory from both sources, different names: builtin wins, and
	// because the rel_paths are identical there is no name conflict.
	builtin := []core.Overlay_Child{core.Overlay_Child{name = "x", rel_path = "r"}}
	resolver := []core.Overlay_Child{core.Overlay_Child{name = "y", rel_path = "r"}}
	got, warn := core.merge_children(builtin, resolver)
	defer free_merge_children(got)
	defer free_merge_warn(warn)
	testing.expectf(t, len(got) == 1, "expected 1 child, got %v", len(got))
	testing.expectf(
		t,
		got[0].name == "x" && got[0].rel_path == "r",
		"got %q/%q",
		got[0].name,
		got[0].rel_path,
	)
	testing.expectf(t, len(warn) == 0, "unexpected warning %q", warn)
}

@(test)
test_merge_resolver_wins_on_name :: proc(t: ^testing.T) {
	// Resolver renames a package to a different rel_path: resolver wins over
	// the colliding builtin entry and a warning is raised.
	builtin := []core.Overlay_Child {
		core.Overlay_Child{name = "foo", rel_path = "a"},
		core.Overlay_Child{name = "bar", rel_path = "b"},
	}
	resolver := []core.Overlay_Child{core.Overlay_Child{name = "foo", rel_path = "c"}}
	got, warn := core.merge_children(builtin, resolver)
	defer free_merge_children(got)
	defer free_merge_warn(warn)
	testing.expectf(t, len(got) == 2, "expected 2 children, got %v", len(got))
	// Sorted by rel_path: b (bar) < c (foo).
	testing.expectf(
		t,
		got[0].name == "bar" && got[0].rel_path == "b",
		"got %q/%q",
		got[0].name,
		got[0].rel_path,
	)
	testing.expectf(
		t,
		got[1].name == "foo" && got[1].rel_path == "c",
		"expected resolver's foo@c to win, got %q/%q",
		got[1].name,
		got[1].rel_path,
	)
	testing.expectf(t, len(warn) > 0, "expected a resolver-wins warning, got empty")
}

@(test)
test_merge_resolver_drops_all_colliding_builtins :: proc(t: ^testing.T) {
	// Two builtin entries share the resolver's winning name -> both dropped.
	builtin := []core.Overlay_Child {
		core.Overlay_Child{name = "foo", rel_path = "aa"},
		core.Overlay_Child{name = "foo", rel_path = "bb"},
		core.Overlay_Child{name = "ok", rel_path = "z"},
	}
	resolver := []core.Overlay_Child{core.Overlay_Child{name = "foo", rel_path = "final"}}
	got, warn := core.merge_children(builtin, resolver)
	defer free_merge_children(got)
	defer free_merge_warn(warn)
	testing.expectf(t, len(got) == 2, "expected 2 children, got %v", len(got))
	// Sorted by rel_path: final (foo) < z (ok).
	testing.expectf(
		t,
		got[0].name == "foo" && got[0].rel_path == "final",
		"got %q/%q",
		got[0].name,
		got[0].rel_path,
	)
	testing.expectf(
		t,
		got[1].name == "ok" && got[1].rel_path == "z",
		"got %q/%q",
		got[1].name,
		got[1].rel_path,
	)
	testing.expectf(t, len(warn) > 0, "expected a resolver-wins warning, got empty")
}

@(test)
test_merge_sort_deterministic :: proc(t: ^testing.T) {
	// Mixed provenance and an out-of-order input: the merge must produce a
	// single deterministic (rel_path, name)-sorted list.
	builtin := []core.Overlay_Child {
		core.Overlay_Child{name = "zeta", rel_path = "aa/zeta"},
		core.Overlay_Child{name = "alpha", rel_path = "aa/alpha"},
		core.Overlay_Child{name = "mid", rel_path = "mid/foo"},
	}
	resolver := []core.Overlay_Child {
		core.Overlay_Child{name = "alpha", rel_path = "bb/alpha"},
		core.Overlay_Child{name = "gamma", rel_path = "aa/gamma"},
	}
	got, warn := core.merge_children(builtin, resolver)
	defer free_merge_children(got)
	defer free_merge_warn(warn)

	// Expected surviving set (alpha@aa/alpha dropped in favor of the resolver):
	//   gamma@aa/gamma, zeta@aa/zeta, alpha@bb/alpha, mid@mid/foo
	// sorted by rel_path: aa/gamma < aa/zeta < bb/alpha < mid/foo.
	expected := []core.Overlay_Child {
		core.Overlay_Child{name = "gamma", rel_path = "aa/gamma"},
		core.Overlay_Child{name = "zeta", rel_path = "aa/zeta"},
		core.Overlay_Child{name = "alpha", rel_path = "bb/alpha"},
		core.Overlay_Child{name = "mid", rel_path = "mid/foo"},
	}
	testing.expectf(t, len(got) == 4, "expected 4 children, got %v", len(got))
	for i in 0 ..< len(expected) {
		testing.expectf(
			t,
			got[i].name == expected[i].name && got[i].rel_path == expected[i].rel_path,
			"child %v: got %q/%q, want %q/%q",
			i,
			got[i].name,
			got[i].rel_path,
			expected[i].name,
			expected[i].rel_path,
		)
	}
	testing.expectf(t, len(warn) > 0, "expected a resolver-wins warning, got empty")
}

@(test)
test_merge_empty_inputs :: proc(t: ^testing.T) {
	got, warn := core.merge_children([]core.Overlay_Child{}, []core.Overlay_Child{})
	defer free_merge_children(got)
	defer free_merge_warn(warn)
	testing.expectf(t, len(got) == 0, "expected 0 children, got %v", len(got))
	testing.expectf(t, len(warn) == 0, "unexpected warning %q", warn)
}

@(test)
test_merge_resolver_only :: proc(t: ^testing.T) {
	// Empty builtin scan: the resolver's children stand alone, sorted.
	got, warn := core.merge_children(
		nil,
		[]core.Overlay_Child {
			core.Overlay_Child{name = "b", rel_path = "z"},
			core.Overlay_Child{name = "a", rel_path = "a"},
		},
	)
	defer free_merge_children(got)
	defer free_merge_warn(warn)
	testing.expectf(t, len(got) == 2, "expected 2 children, got %v", len(got))
	testing.expectf(
		t,
		got[0].name == "a" && got[0].rel_path == "a",
		"got %q/%q",
		got[0].name,
		got[0].rel_path,
	)
	testing.expectf(
		t,
		got[1].name == "b" && got[1].rel_path == "z",
		"got %q/%q",
		got[1].name,
		got[1].rel_path,
	)
	testing.expectf(t, len(warn) == 0, "unexpected warning %q", warn)
}
