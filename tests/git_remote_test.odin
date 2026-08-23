package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "nwscore:core"

// Writes a file with the given contents under dir/path and returns the full path.
write_file :: proc(t: ^testing.T, dir, rel_path, contents: string) -> string {
	full := fmt.tprintf("%s/%s", dir, rel_path)
	err := os.write_entire_file_from_string(full, contents)
	testing.expectf(t, err == nil, "failed writing %q", full)
	return full
}

// Makes dir (and parents).
make_dirs :: proc(t: ^testing.T, dir: string) {
	os.make_directory_all(dir)
	testing.expectf(t, os.is_directory(dir), "mkdir %q failed", dir)
}

@(test)
test_read_origin_url_normal_config :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	child := fmt.tprintf("%s/normal", dir)
	make_dirs(t, fmt.tprintf("%s/.git", child))
	write_file(
		t,
		fmt.tprintf("%s/.git", child),
		"config",
		"[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = https://github.com/user/repo.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n",
	)

	url, ok := core.read_origin_url(child)
	defer delete(url)
	testing.expectf(t, ok, "expected origin URL")
	testing.expectf(t, url == "https://github.com/user/repo.git", "got %q", url)
}

@(test)
test_read_origin_url_worktree_git_file :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	child := fmt.tprintf("%s/worktree", dir)
	make_dirs(t, child)
	write_file(t, child, ".git", "gitdir: /somewhere/else/.git/worktrees/repo\n")

	url, ok := core.read_origin_url(child)
	testing.expectf(t, !ok, "worktree-style .git must yield no URL, got %q", url)
}

@(test)
test_read_origin_url_missing_config_and_missing_child :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)

	// Child exists but has no .git/config.
	child := fmt.tprintf("%s/bare", dir)
	make_dirs(t, child)
	url, ok := core.read_origin_url(child)
	testing.expectf(t, !ok, "missing .git/config must yield no URL, got %q", url)

	// Child directory entirely absent.
	url2, ok2 := core.read_origin_url(fmt.tprintf("%s/nope", dir))
	testing.expectf(t, !ok2, "missing child must yield no URL, got %q", url2)
}

@(test)
test_read_origin_url_multiple_remotes_origin_wins :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	child := fmt.tprintf("%s/missing", dir)
	make_dirs(t, fmt.tprintf("%s/.git", child))
	write_file(
		t,
		fmt.tprintf("%s/.git", child),
		"config",
		"[remote \"upstream\"]\n\turl = https://github.com/up/stream.git\n[remote \"origin\"]\n\turl = git@github.com:user/repo.git\n",
	)

	url, ok := core.read_origin_url(child)
	defer delete(url)
	testing.expectf(t, ok, "expected origin URL among multiple remotes")
	testing.expectf(t, url == "git@github.com:user/repo.git", "got %q", url)
}

@(test)
test_read_origin_url_no_origin_or_no_url_line :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	child := fmt.tprintf("%s/multi", dir)
	make_dirs(t, fmt.tprintf("%s/.git", child))

	// Remotes but no origin.
	write_file(
		t,
		fmt.tprintf("%s/.git", child),
		"config",
		"[remote \"fork\"]\n\turl = https://example.com/fork.git\n",
	)
	url, ok := core.read_origin_url(child)
	testing.expectf(t, !ok, "no origin section must yield no URL, got %q", url)

	// Origin section without a url line.
	write_file(
		t,
		fmt.tprintf("%s/.git", child),
		"config",
		"[remote \"origin\"]\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n",
	)
	url2, ok2 := core.read_origin_url(child)
	testing.expectf(t, !ok2, "origin without url line must yield no URL, got %q", url2)
}

@(test)
test_read_origin_url_whitespace_and_comments :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	child := fmt.tprintf("%s/noorigin", dir)
	make_dirs(t, fmt.tprintf("%s/.git", child))

	contents := strings.join(
		[]string {
			"# top comment",
			"; another comment",
			"",
			"  [ remote \"origin\" ]  ",
			"\turl   =   https://github.com/user/spaced.git  ; trailing comment",
			"# hash = inside comment line",
			"[branch \"main\"]",
			"\tremote = origin",
		},
		"\n",
	)
	write_file(t, fmt.tprintf("%s/.git", child), "config", contents)

	url, ok := core.read_origin_url(child)
	defer delete(url)
	testing.expectf(t, ok, "tolerant parse should find the origin URL")
	testing.expectf(t, url == "https://github.com/user/spaced.git", "got %q", url)
}
