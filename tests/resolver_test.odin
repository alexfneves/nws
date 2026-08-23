package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "nwscore:core"

// ---- Line parser (pure) ----

// free_children frees the owned child name/rel_path strings plus the backing array.
free_resolver_children :: proc(ch: []core.Overlay_Child) {
	for c in ch {
		delete(c.name)
		delete(c.rel_path)
	}
	delete(ch)
}

@(test)
test_resolver_parse_good_lines :: proc(t: ^testing.T) {
	// `\t` in the source is a real tab in the compiled string.
	lines := "pkg\trepo/pkg\n" + "ros\trepo2/node/foo\n" + "spaced\tmono/pkg  \n" + "\n" // trailing whitespace on the field is trimmed// trailing blank line is skipped
	children, ok := core.parse_resolver_lines(lines)
	defer free_resolver_children(children)
	testing.expectf(t, ok, "expected ok=true for clean input")
	testing.expectf(t, len(children) == 3, "expected 3 children, got %v", len(children))
	testing.expectf(
		t,
		children[0].name == "pkg" && children[0].rel_path == "repo/pkg",
		"got %q/%q",
		children[0].name,
		children[0].rel_path,
	)
	testing.expectf(
		t,
		children[1].name == "ros" && children[1].rel_path == "repo2/node/foo",
		"got %q/%q",
		children[1].name,
		children[1].rel_path,
	)
	// trailing whitespace on the field is trimmed -> rel_path == "mono/pkg".
	testing.expectf(
		t,
		children[2].name == "spaced" && children[2].rel_path == "mono/pkg",
		"got %q/%q",
		children[2].name,
		children[2].rel_path,
	)
}

@(test)
test_resolve_parse_malformed_lines :: proc(t: ^testing.T) {
	// no-tab, empty name, empty path, whitespace-only line — all skipped
	// (fail-open); the good lines still survive.
	input :=
		"good\tpkg/foo\n" +
		"notab\n" +
		"\temptyname\n" +
		"emptypath\t\n" +
		"   \n" +
		"second\tmono/bar\n"
	children, ok := core.parse_resolver_lines(input)
	defer free_resolver_children(children)
	testing.expectf(t, ok, "expected ok=true (malformed lines skipped)")
	testing.expectf(t, len(children) == 2, "expected 2 good children, got %v", len(children))
	testing.expectf(
		t,
		children[0].name == "good" && children[0].rel_path == "pkg/foo",
		"got %q/%q",
		children[0].name,
		children[0].rel_path,
	)
	testing.expectf(
		t,
		children[1].name == "second" && children[1].rel_path == "mono/bar",
		"got %q/%q",
		children[1].name,
		children[1].rel_path,
	)
}

@(test)
test_resolve_parse_empty_input :: proc(t: ^testing.T) {
	children, ok := core.parse_resolver_lines("")
	defer free_resolver_children(children)
	testing.expectf(t, ok, "expected ok=true on empty input")
	testing.expectf(t, len(children) == 0, "expected no children, got %v", len(children))
}

@(test)
test_resolve_parse_absolute_path_fails_closed :: proc(t: ^testing.T) {
	children, ok := core.parse_resolver_lines("evil\t/abs/path\n")
	defer free_resolver_children(children)
	testing.expectf(t, !ok, "expected ok=false on absolute rel_path")
	testing.expectf(t, len(children) == 0, "expected no children, got %v", len(children))
}

// ---- Runner (subprocess, fail-open) ----

// write_script writes an executable shell script under dir and returns its path.
write_script :: proc(t: ^testing.T, dir, name, contents: string) -> string {
	full := fmt.tprintf("%s/%s", dir, name)
	err := os.write_entire_file_from_string(full, contents)
	testing.expectf(t, err == nil, "failed writing script %q", full)
	_ = os.change_mode(
		full,
		os.Permissions_Read_All + os.Permissions_Write_All + os.Permissions_Execute_All,
	)
	return full
}

@(test)
test_resolve_run_good :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	script := write_script(
		t,
		dir,
		"good.sh",
		"#!/bin/sh\n" + "echo \"pkg\trepo/pkg\"\n" + "echo \"bar\tmono/bar\"\n",
	)
	children, ok := core.run_resolver(script, dir)
	defer free_resolver_children(children)
	testing.expectf(t, ok, "expected ok=true for a good script")
	testing.expectf(t, len(children) == 2, "expected 2 children, got %v", len(children))
	testing.expectf(
		t,
		children[0].name == "pkg" && children[0].rel_path == "repo/pkg",
		"got %q/%q",
		children[0].name,
		children[0].rel_path,
	)
	testing.expectf(
		t,
		children[1].name == "bar" && children[1].rel_path == "mono/bar",
		"got %q/%q",
		children[1].name,
		children[1].rel_path,
	)
}

@(test)
test_resolve_run_partial :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	script := write_script(
		t,
		dir,
		"partial.sh",
		"#!/bin/sh\n" +
		"echo \"good\tpkg/ok\"\n" +
		"echo \"no-tab-here\"\n" +
		"echo \"\t\"\n" +
		"echo \"empty-path\t\"\n",
	)
	children, ok := core.run_resolver(script, dir)
	defer free_resolver_children(children)
	testing.expectf(t, ok, "expected ok=true (partial output still ok)")
	testing.expectf(
		t,
		len(children) == 1 && children[0].name == "good" && children[0].rel_path == "pkg/ok",
		"expected just [good:pkg/ok], got %v children",
		len(children),
	)
}

@(test)
test_resolve_run_bad_output :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	script := write_script(
		t,
		dir,
		"bad.sh",
		"#!/bin/sh\n" + "echo \"garbage-no-tab\"\n" + "echo \"  \t  \"\n",
	)
	children, ok := core.run_resolver(script, dir)
	defer free_resolver_children(children)
	testing.expectf(t, ok, "expected ok=true (bad output is fail-open, not a crash)")
	testing.expectf(t, len(children) == 0, "expected no children, got %v", len(children))
}

@(test)
test_resolve_run_crash_nonzero :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	script := write_script(
		t,
		dir,
		"crash.sh",
		"#!/bin/sh\n" + "echo \"pkg\trepo/pkg\"\n" + "exit 1\n",
	)
	children, ok := core.run_resolver(script, dir)
	defer free_resolver_children(children)
	testing.expectf(t, !ok, "expected ok=false on nonzero exit")
	testing.expectf(
		t,
		len(children) == 0,
		"expected no children (fail-open), got %v",
		len(children),
	)
}

@(test)
test_resolve_run_missing_script_fails_open :: proc(t: ^testing.T) {
	dir, _ := os.temp_dir(context.allocator)
	defer delete(dir)
	script := fmt.tprintf("%s/does-not-exist.sh", dir)
	children, ok := core.run_resolver(script, dir)
	defer free_resolver_children(children)
	testing.expectf(t, !ok, "expected ok=false on missing script")
	testing.expectf(t, len(children) == 0, "expected no children, got %v", len(children))
}
