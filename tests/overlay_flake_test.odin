package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// Helper building a representative ROS-style single-entry overlay config.
ros_cfg :: proc() -> core.Workspace_Config {
	cfg := core.Workspace_Config {
		kind = .overlay,
	}
	append(
		&cfg.overlays,
		core.Overlay_Entry {
			url = strings.clone("github:lopsided98/nix-ros-overlay/master"),
			attr_path = strings.clone("rosPackages.humble"),
			is_flake = true,
		},
	)
	return cfg
}

// Golden exact-string output for the canonical case: flake overlay entry,
// nixpkgs follows, two children (one from a monorepo subdir), unsorted input.
@(test)
test_overlay_flake_golden :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child {
		{name = "tf2_msgs", rel_path = "ros/tf2_msgs"},
		{name = "tf2", rel_path = "tf2"},
	}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	want := `# nws-generated — do not edit
{
  inputs = {
    overlay0.url = "github:lopsided98/nix-ros-overlay/master";
    nixpkgs.follows = "overlay0/nixpkgs";
  };
  outputs = { ... }@inputs:
  let
    baseViaInput0 = inputs.overlay0.rosPackages.humble or null;
    overlaySource0 = import inputs.overlay0;
    overlayResolved0 = if builtins.isFunction overlaySource0 then overlaySource0 { system = "x86_64-linux"; } else overlaySource0;
    base0 =
      if baseViaInput0 != null
      then baseViaInput0
      else (overlayResolved0.rosPackages.humble or {});
    childCalls0 = {
      tf2 = prev:
        if builtins.pathExists ./.nws/packages/tf2.nix
        then prev.callPackage ./.nws/packages/tf2.nix { }
        else if (prev.tf2 or null) != null
        then prev.tf2.overrideAttrs (final: { src = ./tf2; })
        else if (prev.buildRosPackage or null) != null
        then prev.buildRosPackage {
          pname = "tf2";
          version = "0.0.0";
          src = ./tf2;
        }
        else prev.callPackage ./tf2 { };
      tf2_msgs = prev:
        if builtins.pathExists ./.nws/packages/tf2_msgs.nix
        then prev.callPackage ./.nws/packages/tf2_msgs.nix { }
        else if (prev.tf2_msgs or null) != null
        then prev.tf2_msgs.overrideAttrs (final: { src = ./ros/tf2_msgs; })
        else if (prev.buildRosPackage or null) != null
        then prev.buildRosPackage {
          pname = "tf2_msgs";
          version = "0.0.0";
          src = ./ros/tf2_msgs;
        }
        else prev.callPackage ./ros/tf2_msgs { };
    };
    spliced0 =
      if (base0.overrideScope' or null) != null
      then base0.overrideScope' (final: prev: builtins.mapAttrs (_: f: f prev) childCalls0)
      else base0 // builtins.mapAttrs (_: f: f base0) childCalls0;
  in
  {
    rosPackages.humble = spliced0;
    packages.x86_64-linux = {
      tf2 = spliced0.tf2;
      tf2_msgs = spliced0.tf2_msgs;
      default = (if builtins.hasAttr "nixpkgs" inputs then
        (import inputs.nixpkgs { system = "x86_64-linux"; }).buildEnv {
          name = "nws-workspace-env";
          paths = [
            spliced0.tf2
            spliced0.tf2_msgs
          ];
        }
      else spliced0.tf2);
    };
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

	testing.expectf(
		t,
		core.is_managed_root(got),
		"generated overlay flake does not pass is_managed_root",
	)
}

// The block form carries exactly the whole-file body between the markers:
// BEGIN on its own line, then the identical inner text (inputs + outputs
// sections), then END on its own line. Every binding name stays put
// (`spliced0`, `childCalls0`, `base0`, `overlay0`, `nixpkgs`, `inputs`) so
// user attrs referencing block internals survive regeneration.
@(test)
test_overlay_flake_block_golden :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child {
		{name = "tf2_msgs", rel_path = "ros/tf2_msgs"},
		{name = "tf2", rel_path = "tf2"},
	}

	block := core.generate_overlay_block(children, cfg)
	defer delete(block)
	whole := core.generate_overlay_root_flake(children, cfg)
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
	bindings := []string{"spliced0", "childCalls0", "base0", "overlay0", "nixpkgs", "inputs"}
	for name in bindings {
		testing.expectf(t, strings.contains(inner, name), "binding %q missing from block", name)
	}
}

// Empty children: the block still carries the minimal body (`outputs = { ...
// }: {};`) between its markers.
@(test)
test_overlay_flake_block_empty_children :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)

	block := core.generate_overlay_block(nil, cfg)
	defer delete(block)
	whole := core.generate_overlay_root_flake(nil, cfg)
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

// Calling twice with equal inputs yields byte-identical output regardless of
// child order.
@(test)
test_overlay_flake_determinism :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	a := []core.Overlay_Child {
		{name = "zeta", rel_path = "zeta"},
		{name = "alpha", rel_path = "alpha"},
	}
	b := []core.Overlay_Child {
		{name = "alpha", rel_path = "alpha"},
		{name = "zeta", rel_path = "zeta"},
	}

	got1 := core.generate_overlay_root_flake(a, cfg)
	defer delete(got1)
	got2 := core.generate_overlay_root_flake(b, cfg)
	defer delete(got2)

	testing.expectf(
		t,
		got1 == got2,
		"determinism mismatch:\n--- one ---\n%s\n--- two ---\n%s",
		got1,
		got2,
	)
}

// Zero matched children still produces a valid minimal managed flake.
@(test)
test_overlay_flake_empty_children :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)

	got := core.generate_overlay_root_flake(nil, cfg)
	defer delete(got)

	want := "# nws-generated — do not edit\n{\n  outputs = { ... }: {};\n}\n"
	testing.expectf(t, got == want, "empty-children mismatch:\n%s", got)
	testing.expect(t, core.is_managed_root(got))
}

// Every child splice is guarded by a pathExists check on the user's hidden
// overrides folder, so an absent .nws directory falls through to the bare
// source build and a present file is called with callPackage against the
// spliced scope.
@(test)
test_overlay_flake_user_override_conditional :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child{{name = "turtlebot3_msgs", rel_path = "tb3/turtlebot3_msgs"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	want_block := `turtlebot3_msgs = prev:
        if builtins.pathExists ./.nws/packages/turtlebot3_msgs.nix
        then prev.callPackage ./.nws/packages/turtlebot3_msgs.nix { }
        else if (prev.turtlebot3_msgs or null) != null
        then prev.turtlebot3_msgs.overrideAttrs (final: { src = ./tb3/turtlebot3_msgs; })
        else if (prev.buildRosPackage or null) != null
`
	testing.expectf(
		t,
		strings.contains(got, want_block),
		"user-override conditional missing in:\n%s",
		got,
	)
}

// A child whose name or rel_path cannot be emitted as a bare Nix path token
// (spaces, quotes, backslashes, `#`, `${`, control, or empty) is skipped from
// the flake so it stays evaluable. Safe children are emitted unquoted.
@(test)
test_overlay_flake_weird_names_unsafe_skip :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	// rel_path exercises every reject class is_path_token_safe guards:
	// a space, a double quote and a backslash, plus a safe sibling.
	children := []core.Overlay_Child {
		{name = "good", rel_path = "good"},
		{name = "my pkg", rel_path = "my pkg"},
		{name = "dq", rel_path = "spaced \"quoted\"/dir"},
		{name = "bs", rel_path = "back\\slash/dir"},
	}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	// The unsafe children are skipped — their name appears nowhere (neither in
	// childCalls nor in packages/default).
	testing.expect(t, !strings.contains(got, "my pkg"), "unsafe child 'my pkg' not skipped")
	testing.expect(t, !strings.contains(got, "spaced"), "unsafe quoted child not skipped")
	testing.expect(t, !strings.contains(got, "back\\slash"), "unsafe backslash child not skipped")

	// The safe child is emitted as an unquoted path token.
	testing.expect(
		t,
		strings.contains(got, `src = ./good;`),
		"safe child emitted without unquoted src token in:\n%s",
		got,
	)
	testing.expect(
		t,
		strings.contains(got, `builtins.pathExists ./.nws/packages/good.nix`),
		"safe child pathExists token missing in:\n%s",
		got,
	)
}

// Non-flake entry ("flake": false) emits the fetchTarball import form and
// falls through the cascade to a plain <nixpkgs> channel import.
@(test)
test_overlay_flake_non_flake_entry :: proc(t: ^testing.T) {
	cfg := core.Workspace_Config {
		kind = .overlay,
	}
	defer core.delete_workspace_config(cfg)
	append(
		&cfg.overlays,
		core.Overlay_Entry {
			url = strings.clone("https://example.com/overlay.tar.gz"),
			attr_path = strings.clone("pkgs"),
			overlay_attr = strings.clone("custom"),
			is_flake = false,
		},
	)
	children := []core.Overlay_Child{{name = "foo", rel_path = "foo"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	want := `# nws-generated — do not edit
{
  outputs = { ... }@inputs:
  let
    baseViaInput0 = null;
    overlaySource0 = import (builtins.fetchTarball "https://example.com/overlay.tar.gz");
    overlayResolved0 = if builtins.isFunction overlaySource0 then overlaySource0 { system = "x86_64-linux"; } else overlaySource0;
    base0 =
      if baseViaInput0 != null
      then baseViaInput0
      else (overlayResolved0.pkgs or {});
    childCalls0 = {
      foo = prev:
        if builtins.pathExists ./.nws/packages/foo.nix
        then prev.callPackage ./.nws/packages/foo.nix { }
        else if (prev.foo or null) != null
        then prev.foo.overrideAttrs (final: { src = ./foo; })
        else if (prev.buildRosPackage or null) != null
        then prev.buildRosPackage {
          pname = "foo";
          version = "0.0.0";
          src = ./foo;
        }
        else prev.callPackage ./foo { };
    };
    spliced0 =
      if (base0.overrideScope' or null) != null
      then base0.overrideScope' (final: prev: builtins.mapAttrs (_: f: f prev) childCalls0)
      else base0 // builtins.mapAttrs (_: f: f base0) childCalls0;
  in
  {
    pkgs = spliced0;
    packages.x86_64-linux = {
      foo = spliced0.foo;
      default = (if builtins.hasAttr "nixpkgs" inputs then
        (import inputs.nixpkgs { system = "x86_64-linux"; }).buildEnv {
          name = "nws-workspace-env";
          paths = [
            spliced0.foo
          ];
        }
      else spliced0.foo);
    };
  };
}
`
	testing.expectf(
		t,
		got == want,
		"non-flake mismatch:\n--- got ---\n%s\n--- want ---\n%s",
		got,
		want,
	)
}

// Cascade branch 1: explicit workspace nixpkgs URL wins over everything.
@(test)
test_overlay_flake_cascade_explicit_url :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	cfg.nixpkgs_url = strings.clone("github:NixOS/nixpkgs/nixos-24.11")
	children := []core.Overlay_Child{{name = "foo", rel_path = "foo"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	testing.expect(
		t,
		strings.contains(got, `nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";`),
		"explicit nixpkgs url missing in:\n%s",
		got,
	)
	testing.expect(t, !strings.contains(got, "follows"), "unexpected follows with explicit url")
}

// Cascade branch 2: no explicit URL + flake entry → follows the overlay's
// own nixpkgs.
@(test)
test_overlay_flake_cascade_follows :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child{{name = "foo", rel_path = "foo"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	testing.expect(
		t,
		strings.contains(got, `nixpkgs.follows = "overlay0/nixpkgs";`),
		"follows line missing in:\n%s",
		got,
	)
	testing.expect(
		t,
		!strings.contains(got, "<nixpkgs>"),
		"unexpected channel import in follows mode",
	)
}

// The generated flake uses overrideScope' for scope-shaped base sets and
// prev.callPackage inside the splice so siblings resolve via final.
@(test)
test_overlay_flake_override_scope_form :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child{{name = "a", rel_path = "a"}, {name = "b", rel_path = "b"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	testing.expect(
		t,
		strings.contains(
			got,
			"base0.overrideScope' (final: prev: builtins.mapAttrs (_: f: f prev) childCalls0)",
		),
		"overrideScope' branch missing in:\n%s",
		got,
	)
	count := strings.count(got, "prev.callPackage")
	// Two refs per child: the .nws override call and the bare fallback.
	testing.expectf(
		t,
		count == 2 * len(children),
		"expected %d prev.callPackage refs, got %d",
		2 * len(children),
		count,
	)
	// Children are applied with `f prev`, so sibling splices see each other
	// through the final scope.
	testing.expect(t, strings.contains(got, "(_: f: f prev)"), "prev application missing")
	testing.expect(
		t,
		!strings.contains(got, "pkgs.callPackage"),
		"top-level pkgs.callPackage must not be used",
	)
	// Plain-attrset fallback still present for sets without overrideScope'.
	testing.expect(
		t,
		strings.contains(got, "else base0 // builtins.mapAttrs (_: f: f base0) childCalls0;"),
		"fallback branch missing",
	)
}

// packages.<system> reuses a system segment from the attrPath when present.
@(test)
test_overlay_flake_packages_system_from_attrpath :: proc(t: ^testing.T) {
	testing.expect(
		t,
		core.system_from_attr_path("legacyPackages.x86_64-linux.noetic") == "x86_64-linux",
	)
	testing.expect(t, core.system_from_attr_path("packages.aarch64-darwin") == "aarch64-darwin")
	testing.expect(t, core.system_from_attr_path("pkgs") == "x86_64-linux")

	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child{{name = "foo", rel_path = "foo"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)
	testing.expect(
		t,
		strings.contains(got, "packages.x86_64-linux = {"),
		"packages output missing:\n%s",
		got,
	)
	testing.expect(t, strings.contains(got, "      foo = spliced0.foo;"), "packages entry missing")
}

// default output aggregates every substituted child for a bare build.
@(test)
test_overlay_flake_default_output :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child {
		{name = "tf2", rel_path = "tf2"},
		{name = "tf2_msgs", rel_path = "ros/tf2_msgs"},
	}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	testing.expect(
		t,
		strings.contains(got, "default = (if builtins.hasAttr \"nixpkgs\" inputs then\n"),
		"buildEnv default output missing:\n%s",
		got,
	)
	testing.expect(t, strings.contains(got, "nws-workspace-env"), "buildEnv name missing")
	testing.expect(t, strings.contains(got, "spliced0.tf2\n"), "default tf2 path entry missing")
	testing.expect(
		t,
		strings.contains(got, "spliced0.tf2_msgs\n"),
		"default tf2_msgs path entry missing",
	)
}

// Cascade branch 3: non-flake entry → no inputs section; base comes from
// the fetchTarball-resolved overlay source.
@(test)
test_overlay_flake_cascade_channel :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	cfg.overlays[0].is_flake = false
	children := []core.Overlay_Child{{name = "foo", rel_path = "foo"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	testing.expect(
		t,
		strings.contains(got, `overlaySource0 = import (builtins.fetchTarball`),
		"fetchTarball source missing in:\n%s",
		got,
	)
	testing.expect(
		t,
		!strings.contains(got, "inputs = {"),
		"unexpected inputs section in channel mode",
	)
}
