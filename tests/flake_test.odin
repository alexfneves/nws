package tests

import "core:strings"
import "core:testing"
import "nwscore:core"

// Managed repo: gets pinned to path:./NAME with a # nws: marker appended.
@(test)
test_managed_repo :: proc(t: ^testing.T) {
	input := `inputs = {
  repo-a.url = "github:my-org/repo-a";
  repo-b.url = "github:my-org/repo-b";
};
`
	local := []string{"repo-a"}
	want := `inputs = {
  repo-a.url = "path:./repo-a";  # nws: github:my-org/repo-a
  repo-b.url = "github:my-org/repo-b";
};
`
	got, changed := core.sync_flake(input, local[:])
	defer delete(got)
	testing.expectf(t, changed, "managed rewrite should report changed=true")
	testing.expectf(t, got == want, "unexpected rewrite:\n%q\nwant:\n%q", got, want)
}

// Unmanaged repo (no clone present, never managed): left completely unchanged.
@(test)
test_unmanaged_unchanged :: proc(t: ^testing.T) {
	input := `inputs = {
  repo-a.url = "github:my-org/repo-a";
  repo-b.url = "github:my-org/repo-b";
};
`
	local := []string{}
	got, changed := core.sync_flake(input, local[:])
	defer delete(got)
	testing.expectf(t, !changed, "unmanaged flake should report changed=false")
	testing.expectf(t, got == input, "unmanaged flake must be unchanged:\n%q", got)
}

// Marker already present on a managed line: no duplicate marker is appended.
@(test)
test_marker_not_duplicated :: proc(t: ^testing.T) {
	input := `  repo-a.url = "github:my-org/repo-a";  # nws: github:my-org/repo-a
`
	local := []string{"repo-a"}
	want := `  repo-a.url = "path:./repo-a";  # nws: github:my-org/repo-a
`
	got, _ := core.sync_flake(input, local[:])
	defer delete(got)
	testing.expectf(
		t,
		got == want,
		"marker should be reused, not duplicated:\n%q\nwant:\n%q",
		got,
		want,
	)
	n_markers := count_marker(t, got)
	testing.expectf(t, n_markers == 1, "expected exactly 1 marker, got %d\n%q", n_markers, got)
}

// Idempotency: running the transform twice yields identical output.
@(test)
test_idempotent :: proc(t: ^testing.T) {
	input := `inputs = {
  repo-a.url = "github:my-org/repo-a";
  repo-b.url = "github:my-org/repo-b";
};
`
	local := []string{"repo-a"}
	once, _ := core.sync_flake(input, local[:])
	defer delete(once)
	twice, changed := core.sync_flake(once, local[:])
	defer delete(twice)
	testing.expectf(t, !changed, "second pass should report changed=false")
	testing.expectf(t, twice == once, "transform is not idempotent:\n%q\nwant:\n%q", twice, once)
}

// Remove-clone: a previously managed (marker-holding) line is restored to its
// canonical URL.
@(test)
test_remove_clone_restores_canonical :: proc(t: ^testing.T) {
	input := `  repo-a.url = "path:./repo-a";  # nws: github:my-org/repo-a
`
	local := []string{}
	want := `  repo-a.url = "github:my-org/repo-a";  # nws: github:my-org/repo-a
`
	got, changed := core.sync_flake(input, local[:])
	defer delete(got)
	testing.expectf(t, changed, "restore should report changed=true")
	testing.expectf(t, got == want, "restore failed:\n%q\nwant:\n%q", got, want)
}

// Nested attrs and lines with a dotted prefix are left untouched (fail-open).
@(test)
test_nested_attrs_untouched :: proc(t: ^testing.T) {
	input := `  repo-a.url.foo = "x";
  inputs.repo-a.url = "github:my-org/repo-a";
`
	local := []string{"repo-a"}
	got, changed := core.sync_flake(input, local[:])
	defer delete(got)
	testing.expectf(t, !changed, "nested-attr lines must be left untouched")
	testing.expectf(t, got == input, "nested-attr input must be unchanged:\n%q", got)
}

// Managed repo with extra indentation and a non-marker trailing comment keeps
// its indentation and trailing content, and gains a single marker.
@(test)
test_comment_whitespace_variations :: proc(t: ^testing.T) {
	input := "    repo-a.url = \"github:my-org/repo-a\";  # team comment\n"
	local := []string{"repo-a"}
	want := "    repo-a.url = \"path:./repo-a\";  # team comment  # nws: github:my-org/repo-a\n"
	got, changed := core.sync_flake(input, local[:])
	defer delete(got)
	testing.expectf(t, changed, "managed line with comment should change")
	testing.expectf(t, got == want, "indent/comment handling:\n%q\nwant:\n%q", got, want)
	n_markers := count_marker(t, got)
	testing.expectf(t, n_markers == 1, "expected exactly 1 marker, got %d\n%q", n_markers, got)
}

count_marker :: proc(t: ^testing.T, s: string) -> int {
	return strings.count(s, "# nws:")
}
