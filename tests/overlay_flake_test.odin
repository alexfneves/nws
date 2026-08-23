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
    overlayExpr0 = import inputs.overlay0;
    overlaysList = [
      overlayExpr0.overlays."default"
    ];
    pkgs = import inputs.nixpkgs { overlays = overlaysList; };
  in
  {
    rosPackages.humble = (pkgs.rosPackages.humble or {}) // {
      tf2 = pkgs.callPackage ./tf2 { };
      tf2_msgs = pkgs.callPackage ./ros/tf2_msgs { };
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

// Weird directory names are escaped correctly in attr keys and path strings.
@(test)
test_overlay_flake_weird_names_escaped :: proc(t: ^testing.T) {
	cfg := ros_cfg()
	defer core.delete_workspace_config(cfg)
	children := []core.Overlay_Child{{name = "my pkg", rel_path = "we\"ird/${dir}/my pkg"}}

	got := core.generate_overlay_root_flake(children, cfg)
	defer delete(got)

	testing.expect(
		t,
		strings.contains(got, `"my pkg" = pkgs.callPackage ./we\"ird/\${dir}/my pkg { };`),
		"escaped splice line missing in:\n%s",
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
    overlayExpr0 = import (builtins.fetchTarball "https://example.com/overlay.tar.gz");
    overlaysList = [
      overlayExpr0.overlays."custom"
    ];
    pkgs = import <nixpkgs> { overlays = overlaysList; };
  in
  {
    pkgs = (pkgs.pkgs or {}) // {
      foo = pkgs.callPackage ./foo { };
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
	testing.expect(
		t,
		strings.contains(got, "import inputs.nixpkgs"),
		"explicit-url pkgs import missing",
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
		strings.contains(got, "import inputs.nixpkgs"),
		"follows pkgs import missing",
	)
	testing.expect(
		t,
		!strings.contains(got, "<nixpkgs>"),
		"unexpected channel import in follows mode",
	)
}

// Cascade branch 3: no explicit URL and no flake entry → plain channel
// import and no inputs section at all.
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
		strings.contains(got, "import <nixpkgs> "),
		"channel import missing in:\n%s",
		got,
	)
	testing.expect(
		t,
		!strings.contains(got, "inputs = {"),
		"unexpected inputs section in channel mode",
	)
}
