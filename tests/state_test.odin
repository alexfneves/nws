package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "nwscore:core"

// Round-trips a state containing paths/repos/URLs with spaces and '%' through
// save_state/load_state.
@(test)
test_state_roundtrip :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-state-test.json", dir)
	defer os.remove(path)

	s := core.new_state()
	defer core.destroy_state(&s)
	core.upsert_url(&s, "/home/user/dev/my workspace", "100% repo", "https://github.com/user/repo")
	core.upsert_url(&s, "/home/user/dev/my workspace", "plain", "https://github.com/user/plain")
	core.upsert_url(&s, "/var/lib/ws", "other", "git@github.com:u/o.git")

	if !core.save_state(path, &s) {
		testing.expectf(t, false, "save_state failed for %q", path)
		return
	}

	loaded, ok := core.load_state(path)
	defer core.destroy_state(&loaded)
	testing.expectf(t, ok, "load_state should succeed on a valid file")
	testing.expectf(
		t,
		len(loaded.workspaces) == 2,
		"expected 2 workspaces, got %d",
		len(loaded.workspaces),
	)

	url, found := core.lookup_url(&loaded, "/home/user/dev/my workspace", "100% repo")
	testing.expectf(
		t,
		found && url == "https://github.com/user/repo",
		"url mismatch: got %q (found=%v)",
		url,
		found,
	)

	url, found = core.lookup_url(&loaded, "/home/user/dev/my workspace", "plain")
	testing.expectf(
		t,
		found && url == "https://github.com/user/plain",
		"url mismatch: got %q (found=%v)",
		url,
		found,
	)

	url, found = core.lookup_url(&loaded, "/var/lib/ws", "other")
	testing.expectf(
		t,
		found && url == "git@github.com:u/o.git",
		"url mismatch: got %q (found=%v)",
		url,
		found,
	)
}

// Missing file returns an empty state with ok=false.
@(test)
test_state_missing_file :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-state-does-not-exist.json", dir)
	s, ok := core.load_state(path)
	defer core.destroy_state(&s)
	testing.expectf(t, !ok, "missing file should report ok=false")
	testing.expectf(t, len(s.workspaces) == 0, "expected empty state")
}

// Corrupt JSON returns an empty state instead of crashing.
@(test)
test_state_corrupt_file :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-state-corrupt.json", dir)
	defer os.remove(path)
	_ = os.write_entire_file(path, "{{ not json")

	s, ok := core.load_state(path)
	defer core.destroy_state(&s)
	testing.expectf(t, !ok, "corrupt file should report ok=false")
	testing.expectf(t, len(s.workspaces) == 0, "expected empty state")
}

// save_state leaves no temp file behind and overwrites cleanly on repeat saves.
@(test)
test_state_atomic_write :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/sub/nws-state-atomic.json", dir)
	defer os.remove(path)

	s := core.new_state()
	defer core.destroy_state(&s)
	core.upsert_url(&s, "/ws/a", "repo", "https://example.com/a")

	// Parent directory does not exist yet — save must create it.
	testing.expectf(t, core.save_state(path, &s), "first save_state should succeed")
	tmp := fmt.tprintf("%s.tmp", path)
	testing.expectf(t, !os.exists(tmp), "temp file %q should be renamed away", tmp)
	testing.expectf(t, os.exists(path), "state file %q should exist", path)

	// Overwrite: second save replaces content and again leaves no temp file.
	core.upsert_url(&s, "/ws/a", "repo", "https://example.com/b")
	testing.expectf(t, core.save_state(path, &s), "second save_state should succeed")
	testing.expectf(t, !os.exists(tmp), "temp file %q should be gone after overwrite", tmp)

	reloaded, ok := core.load_state(path)
	defer core.destroy_state(&reloaded)
	testing.expectf(t, ok, "reload after overwrite should succeed")
	url, found := core.lookup_url(&reloaded, "/ws/a", "repo")
	testing.expectf(
		t,
		found && url == "https://example.com/b",
		"expected overwritten url, got %q",
		url,
	)
}

// prune_workspace drops a stale workspace's entries entirely.
@(test)
test_state_prune_workspace :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	path := fmt.tprintf("%s/nws-state-prune.json", dir)
	defer os.remove(path)

	s := core.new_state()
	defer core.destroy_state(&s)
	core.upsert_url(&s, "/ws/stale", "repo1", "https://example.com/1")
	core.upsert_url(&s, "/ws/live", "repo2", "https://example.com/2")

	testing.expectf(
		t,
		core.prune_workspace(&s, "/ws/stale"),
		"pruning a present workspace should return true",
	)
	_, found := core.lookup_url(&s, "/ws/stale", "repo1")
	testing.expectf(t, !found, "stale workspace entries should be gone")
	testing.expectf(
		t,
		len(s.workspaces) == 1,
		"expected 1 remaining workspace, got %d",
		len(s.workspaces),
	)

	// Prune survives a round-trip.
	testing.expectf(t, core.save_state(path, &s), "save after prune should succeed")
	reloaded, ok := core.load_state(path)
	defer core.destroy_state(&reloaded)
	testing.expectf(t, ok, "load after prune should succeed")
	testing.expectf(
		t,
		len(reloaded.workspaces) == 1,
		"pruned entry must not reappear after reload",
	)
	_, found = core.lookup_url(&reloaded, "/ws/stale", "repo1")
	testing.expectf(t, !found, "pruned workspace must be absent from disk state")

	// Pruning a missing workspace is a no-op returning false.
	testing.expectf(
		t,
		!core.prune_workspace(&s, "/ws/nonexistent"),
		"pruning a missing workspace should return false",
	)
}

// upsert_url overwrites existing entries without duplicating keys.
@(test)
test_state_upsert_overwrites :: proc(t: ^testing.T) {
	s := core.new_state()
	defer core.destroy_state(&s)
	core.upsert_url(&s, "/ws", "repo", "https://old.example.com")
	core.upsert_url(&s, "/ws", "repo", "https://new.example.com")

	repos := s.workspaces["/ws"]
	testing.expectf(t, len(repos) == 1, "upsert must not duplicate keys, got %d", len(repos))
	url, found := core.lookup_url(&s, "/ws", "repo")
	testing.expectf(t, found && url == "https://new.example.com", "expected new url, got %q", url)
}

// build_state_json emits deterministic bytes regardless of map order.
@(test)
test_state_json_deterministic :: proc(t: ^testing.T) {
	s := core.new_state()
	defer core.destroy_state(&s)
	core.upsert_url(&s, "/ws/zeta", "b", "https://b.example.com")
	core.upsert_url(&s, "/ws/zeta", "a", "https://a.example.com")
	core.upsert_url(&s, "/ws/alpha", "x", "https://x.example.com")

	t1 := core.build_state_json(&s)
	defer delete(t1)
	t2 := core.build_state_json(&s)
	defer delete(t2)
	testing.expectf(t, t1 == t2, "build_state_json output should be byte-deterministic")

	// Keys appear sorted in the emitted text.
	zeta_idx := strings.index(t1, "/ws/zeta")
	alpha_idx := strings.index(t1, "/ws/alpha")
	a_idx := strings.index(t1, "\"a\":")
	b_idx := strings.index(t1, "\"b\":")
	testing.expectf(t, alpha_idx >= 0 && zeta_idx > alpha_idx, "workspaces should be sorted")
	testing.expectf(t, a_idx >= 0 && b_idx > a_idx, "repos within a workspace should be sorted")
}
