package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

@(test)
test_register_wire_register_encode_legacy_is_just_encoded_path :: proc(t: ^testing.T) {
	req := core.Register_Request {
		path = "/tmp/my ws",
	}
	enc := core.register_encode(&req)
	defer delete(enc)
	testing.expect(t, enc == "/tmp/my%20ws", "got %q", enc)
}

@(test)
test_register_wire_register_parse_legacy_plain_path :: proc(t: ^testing.T) {
	parsed, ok := core.register_parse("/tmp/my%20ws")
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expect(t, parsed.path == "/tmp/my ws", "path %q", parsed.path)
	testing.expect_value(t, parsed.is_overlay, false)
	testing.expect(t, len(parsed.overlays) == 0, "unexpected overlays")
}

@(test)
test_register_wire_register_round_trip_single_overlay :: proc(t: ^testing.T) {
	req := core.Register_Request {
		path        = "/tmp/ws dir",
		is_overlay  = true,
		nixpkgs_url = "github:NixOS/nixpkgs/nixos-25.05",
	}
	append(
		&req.overlays,
		core.Overlay_Entry {
			url = "github:lopsided98/nix-ros-overlay/ros1-25.05",
			attr_path = "rosPackages.noetic",
			is_flake = true,
		},
	)
	defer delete(req.overlays)
	enc := core.register_encode(&req)
	defer delete(enc)

	parsed, ok := core.register_parse(enc)
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expect(t, parsed.path == req.path, "path %q", parsed.path)
	testing.expect_value(t, parsed.is_overlay, true)
	testing.expect(t, parsed.nixpkgs_url == req.nixpkgs_url, "nixpkgs %q", parsed.nixpkgs_url)
	testing.expectf(t, len(parsed.overlays) == 1, "entries %d", len(parsed.overlays))
	if len(parsed.overlays) == 1 {
		testing.expect(t, parsed.overlays[0].url == req.overlays[0].url, "url")
		testing.expect(t, parsed.overlays[0].attr_path == req.overlays[0].attr_path, "attrPath")
		testing.expect(t, parsed.overlays[0].overlay_attr == "", "overlayAttr")
		testing.expect_value(t, parsed.overlays[0].is_flake, true)
	}
}

@(test)
test_register_wire_register_round_trip_full_options_and_specials :: proc(t: ^testing.T) {
	req := core.Register_Request {
		path       = "/tmp/a?b&c=d e%f",
		is_overlay = true,
	}
	append(
		&req.overlays,
		core.Overlay_Entry {
			url = "github:x/y?ref=main",
			attr_path = "pkgs&more",
			overlay_attr = "custom",
			is_flake = false,
		},
	)
	append(
		&req.overlays,
		core.Overlay_Entry{url = "github:a/b", attr_path = "p.q", is_flake = true},
	)
	defer delete(req.overlays)
	enc := core.register_encode(&req)
	defer delete(enc)

	parsed, ok := core.register_parse(enc)
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expect(t, parsed.path == req.path, "path %q", parsed.path)
	testing.expectf(t, len(parsed.overlays) == 2, "entries %d", len(parsed.overlays))
	if len(parsed.overlays) == 2 {
		a, b := parsed.overlays[0], parsed.overlays[1]
		testing.expect(t, a.url == "github:x/y?ref=main", "url0 %q", a.url)
		testing.expect(t, a.attr_path == "pkgs&more", "attr0 %q", a.attr_path)
		testing.expect(t, a.overlay_attr == "custom", "oattr0 %q", a.overlay_attr)
		testing.expect_value(t, a.is_flake, false)
		testing.expect(t, b.url == "github:a/b", "url1 %q", b.url)
		testing.expect(t, b.attr_path == "p.q", "attr1 %q", b.attr_path)
		testing.expect_value(t, b.is_flake, true)
	}
}

@(test)
test_register_wire_register_parse_error_cases :: proc(t: ^testing.T) {
	cases := []string {
		"/tmp/ws?backend=bogus&overlay=x&attrPath=y", // unsupported backend
		"/tmp/ws?backend=overlay", // no entries at all
		"/tmp/ws?backend=overlay&overlay=x", // overlay missing attrPath
		"/tmp/ws?backend=overlay&attrPath=y", // attrPath without overlay
		"/tmp/ws%zz?backend=overlay", // bad percent escape in path
		"", // empty path
	}
	for c in cases {
		parsed, ok := core.register_parse(c)
		core.register_free(&parsed)
		testing.expectf(t, !ok, "expected parse failure for %q", c)
	}
}

@(test)
test_register_wire_register_round_trip_resolver :: proc(t: ^testing.T) {
	req := core.Register_Request {
		path       = "/tmp/ws dir",
		is_overlay = true,
		resolver   = "/home/user/bin/resolve?x&y%z.sh",
	}
	append(
		&req.overlays,
		core.Overlay_Entry{url = "github:x/y", attr_path = "pkgs", is_flake = true},
	)
	defer delete(req.overlays)
	enc := core.register_encode(&req)
	defer delete(enc)

	parsed, ok := core.register_parse(enc)
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expect(t, parsed.path == req.path, "path %q", parsed.path)
	testing.expect(t, parsed.resolver == req.resolver, "resolver round-trip: %q", parsed.resolver)
}

@(test)
test_register_wire_register_parse_resolver_param :: proc(t: ^testing.T) {
	parsed, ok := core.register_parse(
		"/tmp/ws?backend=overlay&resolver=/s%20r.sh&overlay=o&attrPath=a",
	)
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expect(t, parsed.resolver == "/s r.sh", "resolver %q", parsed.resolver)
}

@(test)
test_register_wire_register_parse_unknown_params_ignored_fail_open :: proc(t: ^testing.T) {
	parsed, ok := core.register_parse("/tmp/ws?backend=overlay&future=1&overlay=o&attrPath=a")
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expectf(t, len(parsed.overlays) == 1, "entries %d", len(parsed.overlays))
}

// devShellPackages query param survives the REGISTER encode/parse round-trip
// (comma-joined, percent-encoded, split back into per-attr strings).
@(test)
test_register_wire_round_trip_dev_shell_packages :: proc(t: ^testing.T) {
	req := core.Register_Request {
		path       = "/tmp/overlay ws",
		is_overlay = true,
	}
	append(
		&req.overlays,
		core.Overlay_Entry {
			url = "github:lopsided98/nix-ros-overlay/ros1-25.05",
			attr_path = "legacyPackages.x86_64-linux.noetic",
			is_flake = true,
		},
	)
	pkgs := []string{"ros-base", "gazebo-ros-pkgs", "xacro"}
	for p in pkgs {
		append(&req.dev_shell_packages, strings.clone(p))
	}
	defer {
		delete(req.overlays)
		for p in req.dev_shell_packages {
			delete(p)
		}
		delete(req.dev_shell_packages)
	}
	enc := core.register_encode(&req)
	defer delete(enc)

	parsed, ok := core.register_parse(enc)
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expect(t, parsed.path == req.path, "path %q", parsed.path)
	testing.expect_value(t, len(parsed.dev_shell_packages), 3)
	testing.expect(
		t,
		parsed.dev_shell_packages[0] == "ros-base",
		"got %q",
		parsed.dev_shell_packages[0],
	)
	testing.expect(
		t,
		parsed.dev_shell_packages[2] == "xacro",
		"got %q",
		parsed.dev_shell_packages[2],
	)
}

// Missing devShellPackages → empty list, still a valid overlay request.
@(test)
test_register_wire_no_dev_shell_packages_is_empty :: proc(t: ^testing.T) {
	req := core.Register_Request {
		path       = "/tmp/plain",
		is_overlay = true,
	}
	append(
		&req.overlays,
		core.Overlay_Entry {
			url = "github:lopsided98/nix-ros-overlay/ros1-25.05",
			attr_path = "noetic",
			is_flake = true,
		},
	)
	defer delete(req.overlays)
	enc := core.register_encode(&req)
	defer delete(enc)
	parsed, ok := core.register_parse(enc)
	defer core.register_free(&parsed)
	testing.expect_value(t, ok, true)
	testing.expect(t, len(parsed.dev_shell_packages) == 0, "expected empty list")
}
