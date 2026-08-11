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
	cfg.workspaces = make([dynamic]string)
	defer delete(cfg.workspaces)
	append(&cfg.workspaces, "/home/user/dev/my workspace")
	append(&cfg.workspaces, "/home/user/dev/100% repo")
	append(&cfg.workspaces, "/var/lib/nix/plain")

	if !core.save_config(path, cfg) {
		testing.expectf(t, false, "save_config failed for %q", path)
		return
	}

	loaded, ok := core.load_config(path)
	defer delete_workspaces(&loaded)
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
			loaded.workspaces[i] == cfg.workspaces[i],
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
	defer delete_workspaces(&cfg)
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
	defer delete_workspaces(&cfg)
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

// delete_workspaces frees each workspace string and the backing array.
delete_workspaces :: proc(cfg: ^core.Config) {
	for ws in cfg.workspaces {
		delete(ws)
	}
	delete(cfg.workspaces)
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
