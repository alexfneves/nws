package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// Golden exact-string output for a representative, deliberately unsorted set
// of children: one without a canonical URL (no marker) and two with URLs.
@(test)
test_root_flake_golden :: proc(t: ^testing.T) {
	children := []core.Child_Info {
		{name = "zeta", url = "https://github.com/user/zeta", has_url = true},
		{name = "alpha", has_url = false},
		{name = "mid", url = "https://github.com/user/mid repo", has_url = true},
	}

	got := core.generate_root_flake(children)
	defer delete(got)

	want := `# nws-generated — do not edit
{
  inputs = {
    alpha.url = "path:./alpha";
    mid.url = "path:./mid"; # nws: https://github.com/user/mid repo
    zeta.url = "path:./zeta"; # nws: https://github.com/user/zeta
  };
  outputs = { self, ... }@inputs:
  let
    children = [ "alpha" "mid" "zeta" ];
    delegate = out:
      builtins.listToAttrs (builtins.concatMap
        (child:
          let v = inputs.${child}.${out} or null; in
          if v == null then [] else
          builtins.attrValues (builtins.mapAttrs
            (sys: val: {
              name = sys;
              value = builtins.listToAttrs (builtins.map
                (attrName: { name = "${child}-${attrName}"; value = v.${attrName}; })
                (builtins.attrNames v));
            })
            v)
        )
        children);
  in
  {
    packages = delegate "packages";
    devShells = delegate "devShells";
    apps = delegate "apps";
    checks = delegate "checks";
  };
}
`
	testing.expectf(
		t,
		got == want,
		"golden mismatch:\n--- got ---\n%s\n--- want ---\n%s",
		got,
		want,
	)

	// The generated text must itself be a managed root.
	testing.expectf(t, core.is_managed_root(got), "generated flake should be detected as managed")
}

// Generating twice with identical inputs must produce byte-identical output.
@(test)
test_root_flake_deterministic :: proc(t: ^testing.T) {
	children := []core.Child_Info {
		{name = "beta", url = "https://github.com/u/b", has_url = true},
		{name = "aaa", url = "https://github.com/u/a", has_url = true},
	}

	first := core.generate_root_flake(children)
	defer delete(first)
	second := core.generate_root_flake(children)
	defer delete(second)

	testing.expectf(t, first == second, "generate_root_flake is not byte-deterministic")
}

// Input order must not affect the emitted order: unsorted input yields
// sorted output.
@(test)
test_root_flake_sorts_children :: proc(t: ^testing.T) {
	children := []core.Child_Info {
		{name = "zebra", has_url = false},
		{name = "apple", has_url = false},
		{name = "mango", has_url = false},
	}

	out := core.generate_root_flake(children)
	defer delete(out)

	i_apple := strings.index(out, `apple.url = "path:./apple";`)
	i_mango := strings.index(out, `mango.url = "path:./mango";`)
	i_zebra := strings.index(out, `zebra.url = "path:./zebra";`)
	testing.expectf(
		t,
		i_apple >= 0 && i_mango >= 0 && i_zebra >= 0,
		"missing input lines in output:\n%s",
		out,
	)
	testing.expectf(
		t,
		i_apple < i_mango && i_mango < i_zebra,
		"children not emitted in sorted order:\n%s",
		out,
	)

	// And the sorted children list in the outputs section matches too.
	testing.expectf(
		t,
		strings.contains(out, `children = [ "apple" "mango" "zebra" ];`),
		"outputs section children list wrong:\n%s",
		out,
	)
}

// A child without a canonical URL gets no `# nws:` marker at all.
@(test)
test_root_flake_child_without_url :: proc(t: ^testing.T) {
	children := []core.Child_Info{{name = "plain", has_url = false}}

	out := core.generate_root_flake(children)
	defer delete(out)

	testing.expectf(
		t,
		strings.contains(out, `plain.url = "path:./plain";`),
		"path-pinned input missing:\n%s",
		out,
	)
	testing.expectf(
		t,
		!strings.contains(out, "# nws:"),
		"marker must be omitted when has_url is false:\n%s",
		out,
	)
}

// Markers appear exactly once per child, even when repeated generations run
// on the same input (extract_marker semantics: one marker, never duplicated).
@(test)
test_root_flake_no_duplicate_markers :: proc(t: ^testing.T) {
	children := []core.Child_Info {
		{name = "one", url = "https://github.com/u/one", has_url = true},
		{name = "two", url = "https://github.com/u/two", has_url = true},
	}

	// Generate, then "regenerate" from the same children repeatedly — the
	// marker count per URL must stay at exactly one.
	text := core.generate_root_flake(children)
	defer delete(text)
	for round := 0; round < 3; round += 1 {
		next := core.generate_root_flake(children)
		delete(text)
		text = next
	}

	testing.expectf(
		t,
		strings.count(text, "# nws: https://github.com/u/one") == 1,
		"marker for 'one' duplicated:\n%s",
		text,
	)
	testing.expectf(
		t,
		strings.count(text, "# nws: https://github.com/u/two") == 1,
		"marker for 'two' duplicated:\n%s",
		text,
	)
}

// Empty children list produces a minimal valid managed flake.
@(test)
test_root_flake_empty_children :: proc(t: ^testing.T) {
	out := core.generate_root_flake(nil)
	defer delete(out)

	want := `# nws-generated — do not edit
{
  inputs = {};
  outputs = { self, ... }@inputs:
  let
    children = [ ];
    delegate = out:
      builtins.listToAttrs (builtins.concatMap
        (child:
          let v = inputs.${child}.${out} or null; in
          if v == null then [] else
          builtins.attrValues (builtins.mapAttrs
            (sys: val: {
              name = sys;
              value = builtins.listToAttrs (builtins.map
                (attrName: { name = "${child}-${attrName}"; value = v.${attrName}; })
                (builtins.attrNames v));
            })
            v)
        )
        children);
  in
  {
    packages = delegate "packages";
    devShells = delegate "devShells";
    apps = delegate "apps";
    checks = delegate "checks";
  };
}
`
	testing.expectf(
		t,
		out == want,
		"empty-children golden mismatch:\n--- got ---\n%s\n--- want ---\n%s",
		out,
		want,
	)
	testing.expectf(t, core.is_managed_root(out), "empty flake should be managed")
}

// is_managed_root accepts only the exact header as the first line.
@(test)
test_is_managed_root :: proc(t: ^testing.T) {
	testing.expectf(
		t,
		core.is_managed_root("# nws-generated — do not edit\n{...}"),
		"exact header should be managed",
	)
	testing.expectf(
		t,
		!core.is_managed_root("{\n  description = \"user flake\";\n}\n"),
		"user-authored flake must not be managed",
	)
	testing.expectf(
		t,
		!core.is_managed_root("# just a comment\n# nws-generated — do not edit"),
		"header only counts on the FIRST line",
	)
	testing.expectf(
		t,
		!core.is_managed_root("# nws-generated - do not edit\n{}"),
		"different dash/wording must not match",
	)
	testing.expectf(t, !core.is_managed_root(""), "empty text is not managed")
}
