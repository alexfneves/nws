package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// Whole-file / block wrappers shared by the block-emission tests: stripping
// these from a generated string yields the bare nws body, so the block form
// and the whole-file form can be compared inner-to-inner.
whole_file_prefix :: "# nws-generated — do not edit\n{\n"
whole_file_suffix :: "}\n"
block_prefix :: core.NWS_BLOCK_BEGIN + "\n"
block_suffix :: core.NWS_BLOCK_END + "\n"

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
    perSystem = out: sys:
      builtins.listToAttrs (builtins.concatMap
        (child:
          let v = inputs.${child}.${out}.${sys} or null; in
          if v == null then [] else
            builtins.attrValues (builtins.mapAttrs
              (attrName: val: { name = "${child}-${attrName}"; value = val; })
              v)
        )
        children
      );
    systemsOf = out:
      builtins.attrNames (builtins.foldl' (acc: child: acc // (inputs.${child}.${out} or { })) { } children);
    delegate = out:
      builtins.listToAttrs (builtins.map
        (sys: { name = sys; value = perSystem out sys; })
        (systemsOf out));
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

// The block form carries exactly the whole-file body between the markers:
// BEGIN on its own line, then the identical inner text (inputs + delegated
// outputs), then END on its own line. Binding names are unchanged, so user
// attrs referencing the delegation survive regeneration.
@(test)
test_root_flake_block_golden :: proc(t: ^testing.T) {
	children := []core.Child_Info {
		{name = "zeta", url = "https://github.com/user/zeta", has_url = true},
		{name = "alpha", has_url = false},
		{name = "mid", url = "https://github.com/user/mid repo", has_url = true},
	}

	block := core.generate_root_block(children)
	defer delete(block)
	whole := core.generate_root_flake(children)
	defer delete(whole)

	testing.expectf(
		t,
		strings.has_prefix(block, block_prefix),
		"block must open with the BEGIN marker:\n%s",
		block,
	)
	testing.expectf(
		t,
		strings.has_suffix(block, block_suffix),
		"block must close with the END marker:\n%s",
		block,
	)

	body := whole[len(whole_file_prefix):len(whole) - len(whole_file_suffix)]
	inner := block[len(block_prefix):len(block) - len(block_suffix)]
	testing.expectf(
		t,
		inner == body,
		"block inner text must equal the whole-file body:\n--- block ---\n%s\n--- body ---\n%s",
		inner,
		body,
	)

	// Stable binding names (ISC-7): user attrs reference these across regens.
	bindings := []string{"inputs", "children", "delegate", "perSystem"}
	for name in bindings {
		testing.expectf(t, strings.contains(inner, name), "binding %q missing from block", name)
	}
}

// Empty children: the block still carries the minimal body (`inputs = {}`
// plus the empty delegation) between its markers.
@(test)
test_root_flake_block_empty_children :: proc(t: ^testing.T) {
	block := core.generate_root_block(nil)
	defer delete(block)
	whole := core.generate_root_flake(nil)
	defer delete(whole)

	body := whole[len(whole_file_prefix):len(whole) - len(whole_file_suffix)]
	inner := block[len(block_prefix):len(block) - len(block_suffix)]
	testing.expectf(
		t,
		inner == body,
		"empty block inner text must equal the whole-file body:\n--- block ---\n%s\n--- body ---\n%s",
		inner,
		body,
	)
	testing.expectf(t, strings.has_prefix(block, block_prefix), "BEGIN marker missing")
	testing.expectf(t, strings.has_suffix(block, block_suffix), "END marker missing")
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
    perSystem = out: sys:
      builtins.listToAttrs (builtins.concatMap
        (child:
          let v = inputs.${child}.${out}.${sys} or null; in
          if v == null then [] else
            builtins.attrValues (builtins.mapAttrs
              (attrName: val: { name = "${child}-${attrName}"; value = val; })
              v)
        )
        children
      );
    systemsOf = out:
      builtins.attrNames (builtins.foldl' (acc: child: acc // (inputs.${child}.${out} or { })) { } children);
    delegate = out:
      builtins.listToAttrs (builtins.map
        (sys: { name = sys; value = perSystem out sys; })
        (systemsOf out));
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

// Names that are not valid bare Nix identifiers must be emitted as quoted,
// escaped string keys, and any name embedded in a string literal must have
// `"`, `\`, and `${` escaped so the generated flake stays syntactically valid.
@(test)
test_root_flake_weird_names_escaped :: proc(t: ^testing.T) {
	children := []core.Child_Info {
		{name = `weird-name`, has_url = false},
		{name = `has"quote`, has_url = false},
		{name = "has${dollar}", has_url = false},
	}

	got := core.generate_root_flake(children)
	defer delete(got)

	want := `# nws-generated — do not edit
{
  inputs = {
    "has\"quote".url = "path:./has\"quote";
    "has\${dollar}".url = "path:./has\${dollar}";
    weird-name.url = "path:./weird-name";
  };
  outputs = { self, ... }@inputs:
  let
    children = [ "has\"quote" "has\${dollar}" "weird-name" ];
    perSystem = out: sys:
      builtins.listToAttrs (builtins.concatMap
        (child:
          let v = inputs.${child}.${out}.${sys} or null; in
          if v == null then [] else
            builtins.attrValues (builtins.mapAttrs
              (attrName: val: { name = "${child}-${attrName}"; value = val; })
              v)
        )
        children
      );
    systemsOf = out:
      builtins.attrNames (builtins.foldl' (acc: child: acc // (inputs.${child}.${out} or { })) { } children);
    delegate = out:
      builtins.listToAttrs (builtins.map
        (sys: { name = sys; value = perSystem out sys; })
        (systemsOf out));
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
		"weird-name golden mismatch:\n--- got ---\n%s\n--- want ---\n%s",
		got,
		want,
	)
}

@(test)
test_root_flake_sibling_overrides :: proc(t: ^testing.T) {
	children := []core.Child_Info {
		{name = "app-b", deps = []string{"lib-a", "nixpkgs", "missing"}},
		{name = "lib-a"},
	}
	got := core.generate_root_flake(children)
	defer delete(got)

	testing.expectf(
		t,
		strings.contains(got, `app-b.inputs.lib-a.url = "path:./lib-a";`),
		"expected sibling override for lib-a, got:\n%s",
		got,
	)
	// Non-sibling deps must not be wired.
	testing.expect(t, !strings.contains(got, "inputs.nixpkgs.url"))
	testing.expect(t, !strings.contains(got, "inputs.missing.url"))
}

@(test)
test_parse_flake_input_names :: proc(t: ^testing.T) {
	text := `
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-parts.url = "github:hercules-ci/flake-parts";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "x";
      inputs = {
        pyproject-nix.follows = "pyproject-nix";
      };
    };
  };
  outputs = { self, nixpkgs }: {};
}
`
	got := core.parse_flake_input_names(text)
	defer {
		for g in got {
			delete(g)
		}
		delete(got)
	}
	expect_sorted_names :: proc(t: ^testing.T, got: []string, want: []string) {
		testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want)
		for g, i in got {
			testing.expectf(t, i < len(want) && g == want[i], "got %v, want %v", got, want)
		}
	}
	expect_sorted_names(
		t,
		got,
		[]string{"nixpkgs", "flake-parts", "pyproject-nix", "pyproject-build-systems"},
	)
}
