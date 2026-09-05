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

	want := `{
# nws block — managed by nws; do not edit
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
# /nws block
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
		core.has_nws_block(got),
		"generated overlay flake should be detected by its nws block",
	)
}

// The block form carries the whole nws body between the markers: BEGIN on
// its own line, then the identical inner text (inputs + outputs sections),
// then END on its own line. The outputs return set is LEFT OPEN at the END
// marker — the block ends inside `in {` after the generated attrs — and the
// whole-file create shape closes the set and the flake: `{` + block +
// `  };` + `}`. Every binding name stays put (`spliced0`, `childCalls0`,
// `base0`, `overlay0`, `nixpkgs`, `inputs`) so user attrs referencing block
// internals — written below the END marker, still inside outputs — survive
// regeneration. patch_flake("", block) produces the same bytes as the
// whole-file form.
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

	// ISC-3: the whole-file form wraps the block in a minimal `{ ... }` shell
	// (no whole-file header) plus the return-set closer.
	want_whole := strings.concatenate({"{\n", block, "  };\n}\n"})
	defer delete(want_whole)
	testing.expectf(
		t,
		whole == want_whole,
		"whole-file form must be `{` + block + `  };` + `}`:\n--- got ---\n%s\n--- want ---\n%s",
		whole,
		want_whole,
	)

	// The daemon's create path must produce exactly the same bytes.
	created, ok := core.patch_flake("", block)
	defer delete(created)
	testing.expectf(t, ok, "create path must succeed")
	testing.expectf(t, created == whole, "patch_flake(\"\") must equal the create-shape flake")

	// Stable binding names (ISC-7): user attrs reference these across regens.
	inner := block[len(block_prefix):len(block) - len(block_suffix)]
	bindings := []string{"spliced0", "childCalls0", "base0", "overlay0", "nixpkgs", "inputs"}
	for name in bindings {
		testing.expectf(t, strings.contains(inner, name), "binding %q missing from block", name)
	}
}

// Empty children: the block still carries the minimal body between its
// markers — an open `outputs = { ... }@inputs:` return set — and the
// whole-file form still wraps it without any header, closing the set with
// `  };` and the flake with `}`.
@(test)
test_overlay_flake_block_empty_children :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)

	block := core.generate_overlay_block(nil, cfg)
	defer delete(block)
	whole := core.generate_overlay_root_flake(nil, cfg)
	defer delete(whole)

	testing.expectf(t, strings.has_prefix(block, block_prefix), "BEGIN marker missing")
	testing.expectf(t, strings.has_suffix(block, block_suffix), "END marker missing")

	// ISC-10: zero children still yields a valid, block-carrying flake whose
	// body is the minimal open return set.
	testing.expectf(
		t,
		strings.contains(block, "  outputs = { ... }@inputs:\n  {\n"),
		"minimal body missing",
	)

	want_whole := strings.concatenate({"{\n", block, "  };\n}\n"})
	defer delete(want_whole)
	testing.expectf(
		t,
		whole == want_whole,
		"empty whole-file form must be `{` + block + `  };` + `}`:\n--- got ---\n%s\n--- want ---\n%s",
		whole,
		want_whole,
	)
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

	want := `{
# nws block — managed by nws; do not edit
  outputs = { ... }@inputs:
  {
# /nws block
  };
}
`
	testing.expectf(t, got == want, "empty-children mismatch:\n%s", got)
	testing.expect(t, core.has_nws_block(got))
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

	want := `{
# nws block — managed by nws; do not edit
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
# /nws block
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

// The managed devShell follows the standard nix-ros-overlay pattern: mkShell +
// spliced0.buildEnv env with children FIRST (clone builds win collisions),
// ignoreCollisions (children's propagated deps contain the overlay's original
// siblings), no shellHook, no env-var manipulation.
@(test)
test_overlay_flake_devshell_emission :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	append(&cfg.dev_shell_packages, strings.clone("ros-base"))
	append(&cfg.dev_shell_packages, strings.clone("gazebo-ros-pkgs"))
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child {
		{name = "tf2", rel_path = "tf2"},
		{name = "tf2_msgs", rel_path = "ros/tf2_msgs"},
	}

	got := core.generate_overlay_block(children, cfg, emit_devshell = true)
	defer delete(got)

	testing.expect(
		t,
		strings.contains(got, "devShells.x86_64-linux.default = let"),
		"devShells attr missing",
	)
	testing.expect(
		t,
		strings.contains(got, `pkgsN = import inputs.nixpkgs { system = "x86_64-linux"; };`),
		"pkgsN binding missing",
	)
	testing.expect(
		t,
		strings.contains(got, "ignoreCollisions = true;"),
		"ignoreCollisions missing",
	)
	testing.expect(t, strings.contains(got, "packages = [ env ];"), "standard shape missing")
	testing.expect(t, strings.contains(got, "spliced0.gazebo-ros-pkgs"), "extra missing")
	testing.expect(
		t,
		!strings.contains(got, "shellHook") && !strings.contains(got, "export "),
		"devShell must not manipulate the environment",
	)
	// Children first: the clone builds must precede configured extras so the
	// env's collision resolution keeps them.
	idx_tf2 := strings.index(got, "spliced0.tf2\n")
	idx_ros := strings.index(got, "spliced0.ros-base")
	testing.expect(t, idx_tf2 >= 0 && idx_ros > idx_tf2, "children must precede extras in paths")

	// emit_devshell = false → no devShell attr at all.
	none := core.generate_overlay_block(children, cfg, emit_devshell = false)
	defer delete(none)
	testing.expect(t, !strings.contains(none, "devShells."), "no devShell expected")
}

// No nixpkgs input (all non-flake overlays, no nixpkgs.url) → the devShell
// attr is skipped fail-open even when requested.
@(test)
test_overlay_flake_devshell_skipped_without_nixpkgs_input :: proc(t: ^testing.T) {
	cfg := core.Workspace_Config {
		kind = .overlay,
	}
	append(
		&cfg.overlays,
		core.Overlay_Entry {
			url = strings.clone("https://example.com/overlay.tar.gz"),
			attr_path = strings.clone("pkgs"),
			is_flake = false,
		},
	)
	append(&cfg.dev_shell_packages, strings.clone("ros-base"))
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child{{name = "tf2", rel_path = "tf2"}}

	got := core.generate_overlay_block(children, cfg, emit_devshell = true)
	defer delete(got)
	testing.expect(t, !strings.contains(got, "devShells."), "devShell must be skipped")
}

// An overlay entry whose attrPath IS the convenience packages.<system> attr
// itself (Hyprland-style: `packages.x86_64-linux`) must not emit the same
// attr twice — that would make the flake fail to eval ("attribute
// 'packages.x86_64-linux' already defined"). The per-entry output is emitted
// in the MERGED form (`packages.x86_64-linux = spliced0 // { ... }`): the
// full spliced set is preserved via a Nix `//` merge and the convenience
// children/default body rides on top (body keys win — same children, plus
// `default` only the body has). The standalone convenience output is skipped.
@(test)
test_overlay_flake_packages_attrpath_no_collision :: proc(t: ^testing.T) {
	cfg := core.Workspace_Config {
		kind = .overlay,
	}
	defer core.delete_workspace_config(cfg)
	append(
		&cfg.overlays,
		core.Overlay_Entry {
			url = strings.clone("github:hyprwm/hyprlang"),
			attr_path = strings.clone("packages.x86_64-linux"),
			is_flake = true,
		},
	)
	children := []core.Overlay_Child{{name = "hyprlang", rel_path = "hyprlang"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	// Exactly ONE packages.x86_64-linux definition, in the merged form.
	testing.expectf(
		t,
		strings.count(got, "packages.x86_64-linux =") == 1,
		"expected exactly one packages.x86_64-linux definition:\n%s",
		got,
	)
	testing.expect(
		t,
		strings.contains(got, "    packages.x86_64-linux = spliced0 // {\n"),
		"merged form (spliced set // convenience body) missing:\n%s",
		got,
	)
	// The standalone convenience output must NOT be emitted a second time.
	testing.expect(
		t,
		!strings.contains(got, "    packages.x86_64-linux = {\n"),
		"standalone convenience output must be skipped when the attrPath collides:\n%s",
		got,
	)
	// Both sides of the merge survive: the child entry and the default
	// buildEnv are still present under the merged attr.
	testing.expect(
		t,
		strings.contains(got, "hyprlang = spliced0.hyprlang;"),
		"convenience child entry missing from the merged body:\n%s",
		got,
	)
	testing.expect(
		t,
		strings.contains(got, "default = (if builtins.hasAttr \"nixpkgs\" inputs then\n"),
		"convenience default buildEnv missing from the merged body:\n%s",
		got,
	)
}

// Multi-overlay configs: the packages.<sys> suppression must hold for ANY
// colliding entry, not just entry 0. Shape 1 is the review's failing case —
// entry 0 non-colliding (`legacyPackages.x86_64-linux.foo`) and a LATER
// (non-zero) entry colliding (`packages.x86_64-linux`) used to emit BOTH the
// merged per-entry form AND the standalone convenience output, a duplicate
// "attribute 'packages.x86_64-linux' already defined" eval failure. Shape 2
// — two entries whose attrPath is the SAME packages.<sys> — must likewise
// define the attr exactly once (the first colliding entry wins). In both
// shapes exactly ONE packages.x86_64-linux definition survives, in the
// merged form; the standalone convenience output never coexists with it.
@(test)
test_overlay_flake_packages_attrpath_multi_overlay_collision :: proc(t: ^testing.T) {
	children := []core.Overlay_Child{{name = "hyprlang", rel_path = "hyprlang"}}

	// Shape 1: later (non-zero) entry collides while entry 0 does not.
	cfg := core.Workspace_Config {
		kind = .overlay,
	}
	defer core.delete_workspace_config(cfg)
	append(
		&cfg.overlays,
		core.Overlay_Entry {
			url = strings.clone("github:example/overlay-a"),
			attr_path = strings.clone("legacyPackages.x86_64-linux.foo"),
			is_flake = true,
		},
	)
	append(
		&cfg.overlays,
		core.Overlay_Entry {
			url = strings.clone("github:hyprwm/hyprlang"),
			attr_path = strings.clone("packages.x86_64-linux"),
			is_flake = true,
		},
	)

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	testing.expectf(
		t,
		strings.count(got, "packages.x86_64-linux =") == 1,
		"later colliding entry must emit exactly one packages.x86_64-linux (merged form):\n%s",
		got,
	)
	testing.expect(
		t,
		strings.contains(got, "    packages.x86_64-linux = spliced1 // {\n"),
		"the later colliding entry must take the merged form under its own spliced set:\n%s",
		got,
	)
	testing.expect(
		t,
		!strings.contains(got, "    packages.x86_64-linux = {\n"),
		"the standalone convenience output must be suppressed once ANY entry collides:\n%s",
		got,
	)
	testing.expect(
		t,
		strings.contains(got, "    legacyPackages.x86_64-linux.foo = spliced0;\n"),
		"the non-colliding entry's own output attr must stay untouched:\n%s",
		got,
	)

	// Shape 2: two entries whose attrPath IS the same packages.<sys>.
	cfg2 := core.Workspace_Config {
		kind = .overlay,
	}
	defer core.delete_workspace_config(cfg2)
	append(
		&cfg2.overlays,
		core.Overlay_Entry {
			url = strings.clone("github:hyprwm/hyprlang"),
			attr_path = strings.clone("packages.x86_64-linux"),
			is_flake = true,
		},
	)
	append(
		&cfg2.overlays,
		core.Overlay_Entry {
			url = strings.clone("github:hyprwm/hyprutils"),
			attr_path = strings.clone("packages.x86_64-linux"),
			is_flake = true,
		},
	)

	got2 := core.generate_overlay_root_flake(children, cfg2)
	defer delete(got2)

	testing.expectf(
		t,
		strings.count(got2, "packages.x86_64-linux =") == 1,
		"duplicate colliding entries must define the attr exactly once:\n%s",
		got2,
	)
	testing.expect(
		t,
		strings.contains(got2, "    packages.x86_64-linux = spliced0 // {\n"),
		"the merged form must come from the first colliding entry:\n%s",
		got2,
	)
	testing.expect(
		t,
		!strings.contains(got2, "= spliced1 // "),
		"the second colliding entry must NOT re-emit the attr:\n%s",
		got2,
	)
}
