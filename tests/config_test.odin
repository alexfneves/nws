package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "nwscore:core"

// Round-trips a config containing a path with a space and a '%' through
// save_config/load_config.
@(test)
test_config_roundtrip :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-config-test.json", dir)
	defer os.remove(path)

	cfg := core.Config {
		port = 17424,
	}
	cfg.workspaces = make([dynamic]core.Workspace_Config)
	defer core.delete_workspaces(&cfg)
	append(
		&cfg.workspaces,
		core.Workspace_Config{name = strings.clone("/home/user/dev/my workspace")},
	)
	append(
		&cfg.workspaces,
		core.Workspace_Config{name = strings.clone("/home/user/dev/100% repo")},
	)
	append(&cfg.workspaces, core.Workspace_Config{name = strings.clone("/var/lib/nix/plain")})

	if !core.save_config(path, cfg) {
		testing.expectf(t, false, "save_config failed for %q", path)
		return
	}

	loaded, ok := core.load_config(path)
	defer core.delete_workspaces(&loaded)
	testing.expectf(t, ok, "load_config should succeed on a valid file")
	testing.expectf(
		t,
		loaded.port == cfg.port,
		"port mismatch: got %d want %d",
		loaded.port,
		cfg.port,
	)
	testing.expectf(
		t,
		len(loaded.workspaces) == len(cfg.workspaces),
		"workspace count mismatch: got %d want %d",
		len(loaded.workspaces),
		len(cfg.workspaces),
	)
	for i in 0 ..< len(cfg.workspaces) {
		testing.expectf(
			t,
			loaded.workspaces[i].name == cfg.workspaces[i].name,
			"workspace %d mismatch: got %q want %q",
			i,
			loaded.workspaces[i],
			cfg.workspaces[i],
		)
	}
}

// Missing file returns defaults (DEFAULT_PORT, no workspaces) and ok=false.
@(test)
test_config_missing_file_defaults :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-config-does-not-exist.json", dir)
	cfg, ok := core.load_config(path)
	defer core.delete_workspaces(&cfg)
	testing.expectf(t, !ok, "missing file should report ok=false")
	testing.expectf(t, cfg.port == core.DEFAULT_PORT, "expected DEFAULT_PORT, got %d", cfg.port)
	testing.expectf(t, len(cfg.workspaces) == 0, "expected no workspaces")
}

// Corrupt JSON falls back to defaults instead of crashing.
@(test)
test_config_corrupt_file_defaults :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-config-corrupt.json", dir)
	defer os.remove(path)
	_ = os.write_entire_file(path, "this is {{ not json")

	cfg, ok := core.load_config(path)
	defer core.delete_workspaces(&cfg)
	testing.expectf(t, !ok, "corrupt file should report ok=false")
	testing.expectf(t, cfg.port == core.DEFAULT_PORT, "expected DEFAULT_PORT, got %d", cfg.port)
}

// URL encode/decode round-trip for spaces, '%', and '/' preservation.
@(test)
test_url_roundtrip :: proc(t: ^testing.T) {
	original := "/home/user/dev/my workspace/100% done/x"
	encoded := core.encode(original)
	defer delete(encoded)
	testing.expectf(
		t,
		strings.count(encoded, "%20") == 2,
		"each space should be encoded, got %q",
		encoded,
	)
	testing.expectf(
		t,
		strings.count(encoded, "%25") == 1,
		"%% should be encoded once, got %q",
		encoded,
	)
	testing.expectf(
		t,
		strings.contains(encoded, "/"),
		"slashes must be preserved, got %q",
		encoded,
	)

	decoded, ok := core.decode(encoded)
	defer delete(decoded)
	testing.expectf(t, ok, "decode should succeed")
	testing.expectf(
		t,
		decoded == original,
		"round-trip mismatch: got %q want %q",
		decoded,
		original,
	)
}

// Legacy string-array workspaces load as .flake workspaces and re-serialize
// byte-stably (ISC-1).
@(test)
test_config_legacy_array_byte_stable :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-config-legacy.json", dir)
	defer os.remove(path)

	original := "{\n  \"port\": 17500,\n  \"workspaces\": [\"/a/b\", \"/c d/e%f\"]\n}\n"
	_ = os.write_entire_file(path, original)

	cfg, ok := core.load_config(path)
	defer core.delete_workspaces(&cfg)
	testing.expectf(t, ok, "legacy config should parse")
	testing.expectf(
		t,
		len(cfg.workspaces) == 2,
		"expected 2 workspaces, got %d",
		len(cfg.workspaces),
	)
	for ws in cfg.workspaces {
		testing.expectf(t, ws.kind == .flake, "legacy entries must be kind=.flake")
		testing.expectf(t, len(ws.overlays) == 0, "legacy entries must have no overlays")
		testing.expectf(t, len(ws.nixpkgs_url) == 0, "legacy entries must have no nixpkgs url")
	}
	testing.expectf(
		t,
		cfg.workspaces[0].name == "/a/b",
		"name mismatch: %q",
		cfg.workspaces[0].name,
	)

	if !core.save_config(path, cfg) {
		testing.expectf(t, false, "save_config failed")
		return
	}
	data, rerr := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expectf(t, rerr == nil, "re-read failed")
	testing.expectf(
		t,
		string(data) == original,
		"rewrite not byte-stable:\ngot:  %q\nwant: %q",
		string(data),
		original,
	)
}

// Object-form overlay workspace round-trips through save/load (ISC-2).
@(test)
test_config_overlay_object_roundtrip :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-config-overlay.json", dir)
	defer os.remove(path)

	text := `{"port": 17424, "workspaces": [{"name": "/ros/ws", "backend": "overlay", "overlays": [{"url": "github:lopsided98/nix-ros-overlay/master", "attrPath": "rosPackages.humble", "flake": false}], "nixpkgs": "github:NixOS/nixpkgs/nixos-24.11"}]}`
	_ = os.write_entire_file(path, text)

	cfg, ok := core.load_config(path)
	defer core.delete_workspaces(&cfg)
	testing.expectf(t, ok, "object-form config should parse")
	testing.expectf(t, len(cfg.workspaces) == 1, "expected 1 workspace")
	ws := cfg.workspaces[0]
	testing.expectf(t, ws.name == "/ros/ws", "name mismatch: %q", ws.name)
	testing.expectf(t, ws.kind == .overlay, "kind should be .overlay")
	testing.expectf(
		t,
		ws.nixpkgs_url == "github:NixOS/nixpkgs/nixos-24.11",
		"nixpkgs mismatch: %q",
		ws.nixpkgs_url,
	)
	testing.expectf(t, len(ws.overlays) == 1, "expected 1 overlay entry")
	ov := ws.overlays[0]
	testing.expectf(
		t,
		ov.url == "github:lopsided98/nix-ros-overlay/master",
		"url mismatch: %q",
		ov.url,
	)
	testing.expectf(t, ov.attr_path == "rosPackages.humble", "attrPath mismatch: %q", ov.attr_path)
	testing.expectf(t, !ov.is_flake, "flake:false should be preserved")

	if !core.save_config(path, cfg) {
		testing.expectf(t, false, "save_config failed")
		return
	}
	again, ok2 := core.load_config(path)
	defer core.delete_workspaces(&again)
	testing.expectf(t, ok2, "reload after save failed")
	testing.expectf(
		t,
		len(again.workspaces) == 1 && again.workspaces[0].kind == .overlay,
		"overlay kind lost on reload",
	)
	testing.expectf(
		t,
		len(again.workspaces[0].overlays) == 1 && again.workspaces[0].overlays[0].url == ov.url,
		"overlay entry lost on reload",
	)
}

// Defaults/fail-open for object-form entries: missing name or overlays with
// missing required fields are skipped; optional defaults apply.
@(test)
test_config_object_form_defaults_failopen :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-config-failopen.json", dir)
	defer os.remove(path)

	text := `{"workspaces": [
	  {"name": "/good/overlay", "backend": "overlay", "overlays": [{"url": "github:x/y/main", "attrPath": "pkgs"}]},
	  {"backend": "overlay"},
	  {"name": "/no/overlays", "backend": "overlay", "overlays": [{"url": ""}, {"attrPath": "only"}]},
	  {"name": "/plain/obj", "backend": "flake"},
	  42
	]}`
	_ = os.write_entire_file(path, text)

	cfg, _ := core.load_config(path)
	defer core.delete_workspaces(&cfg)
	// /good/overlay + /no/overlays + /plain/obj survive; the rest are skipped.
	testing.expectf(
		t,
		len(cfg.workspaces) == 3,
		"expected 3 surviving workspaces, got %d",
		len(cfg.workspaces),
	)
	good := cfg.workspaces[0]
	testing.expectf(t, good.kind == .overlay && len(good.overlays) == 1, "good entry misparsed")
	testing.expectf(t, good.overlays[0].is_flake, "is_flake should default to true")
	testing.expectf(
		t,
		len(good.overlays[0].overlay_attr) == 0,
		"overlay_attr should default to empty",
	)
	testing.expectf(
		t,
		cfg.workspaces[1].name == "/no/overlays" && len(cfg.workspaces[1].overlays) == 0,
		"overlay entries missing required fields must be dropped",
	)
	testing.expectf(t, cfg.workspaces[2].kind == .flake, "backend flake object → kind .flake")
}

// Malformed percent-escape is rejected.
@(test)
test_url_decode_malformed :: proc(t: ^testing.T) {
	_, ok := core.decode("100%") // dangling '%'
	testing.expectf(t, !ok, "dangling %% should fail")
	_, ok = core.decode("100%2") // only one hex digit
	testing.expectf(t, !ok, "truncated hex escape should fail")
	_, ok = core.decode("a%zz") // invalid hex
	testing.expectf(t, !ok, "invalid hex should fail")
}
