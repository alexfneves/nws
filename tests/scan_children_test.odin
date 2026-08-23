package tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "nwscore:core"

// ---- Fake in-memory directory tree ----
//
// The scanner's listing seam (core.Dir_Listing_Proc) is injected with a fake
// backed by a FILE-SCOPE STATIC string (no heap needed at load, so it is safe
// under the parallel test runner): one "\n"-separated "DIR=ENTRIES" line per
// directory, entries comma-separated ("d:name" = dir, "f:name" = file). The
// scanner never touches real disk here.
//
// A special case generates the count-cap fixture ("cmb", 202 dirs) on the
// fly, because it is too large to hand-write.

fake_spec_src := `fc1=d:outer,d:no
fc1/outer=f:flake.nix,d:inner
fc1/no=d:deeper
fc1/no/deeper=f:flake.nix
nest=d:monorepo
nest/monorepo=d:pkg
nest/monorepo/pkg=d:foo,d:bar
nest/monorepo/pkg/foo=f:flake.nix
nest/monorepo/pkg/bar=f:x.nix
dp=d:l1
dp/l1=d:l2
dp/l1/l2=d:l3
dp/l1/l2/l3=d:l4
hid=d:.git,d:.nws,d:visible,f:base.nix,d:.hiddenpkg
hid/visible=f:flake.nix
srt=d:z,d:b,d:a
srt/a=f:flake.nix
srt/b=f:flake.nix
srt/z=f:flake.nix
ven=d:vendor,d:monorepo,d:.vendor
ven/vendor=f:pack.nix,d:sub
ven/monorepo=d:pkg
ven/monorepo/pkg=d:foo
ven/monorepo/pkg/foo=f:flake.nix
emp=`

// fake_listing is the injected seam. It returns ([]core.Dir_Entry, ok): ok is
// false for dirs absent from the spec (fail-open); names are cloned into the
// passed allocator so the scanner can free them.
fake_listing :: proc(
	dir: string,
	allocator: mem.Allocator,
) -> (
	entries: []core.Dir_Entry,
	ok: bool,
) {
	// Count-cap fixture, generated: 202 sibling dirs p0..p201 (each a package).
	if dir == "cmb" {
		d := make([dynamic]core.Dir_Entry, 0, 202, allocator)
		for i in 0 ..< 202 {
			nm := fmt.tprintf("p%d", i)
			append(&d, core.Dir_Entry{name = strings.clone(nm, allocator), is_dir = true})
		}
		return d[:], true
	}
	if strings.starts_with(dir, "cmb/") {
		out := make([]core.Dir_Entry, 1, allocator)
		out[0] = core.Dir_Entry {
			name   = strings.clone("flake.nix", allocator),
			is_dir = false,
		}
		return out, true
	}

	lines := strings.split(fake_spec_src, "\n", allocator)
	defer delete(lines)
	for line in lines {
		if len(line) == 0 {
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		if line[:eq] != dir {
			continue
		}
		rest := line[eq + 1:]
		if len(rest) == 0 {
			return []core.Dir_Entry{}, true // empty dir (e.g. root "emp")
		}
		parts := strings.split(rest, ",", allocator)
		defer delete(parts)
		d := make([dynamic]core.Dir_Entry, 0, len(parts), allocator)
		for p in parts {
			if len(p) < 3 {
				continue
			}
			isd := p[0] == 'd'
			nm := p[2:]
			append(&d, core.Dir_Entry{name = strings.clone(nm, allocator), is_dir = isd})
		}
		return d[:], true
	}
	return []core.Dir_Entry{}, false
}

// free_children frees the owned name/rel_path strings plus the backing array
// of one scan result.
free_children :: proc(ch: []core.Overlay_Child) {
	for c in ch {
		delete(c.name)
		delete(c.rel_path)
	}
	delete(ch)
}

// free_warn frees a scan warning when it is a heap string ("" is not).
free_warn :: proc(w: string) {
	if len(w) > 0 {
		delete(w)
	}
}

@(test)
test_scan_find_vs_clamp :: proc(t: ^testing.T) {
	got, warn := core.scan_overlay_children(fake_listing, "fc1")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 2, "expected 2 children, got %v", len(got))
	testing.expectf(
		t,
		got[0].rel_path == "no/deeper" && got[0].name == "deeper",
		"expected [no/deeper (deeper), ...], got %v/%v",
		got[0].rel_path,
		got[0].name,
	)
	testing.expectf(
		t,
		got[1].rel_path == "outer" && got[1].name == "outer",
		"expected [..., outer (outer)], got %v/%v",
		got[1].rel_path,
		got[1].name,
	)
	testing.expectf(t, len(warn) == 0, "unexpected warning %q", warn)
}

@(test)
test_scan_nested_monorepo :: proc(t: ^testing.T) {
	got, warn := core.scan_overlay_children(fake_listing, "nest")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 2, "expected 2 children, got %v", len(got))
	testing.expectf(
		t,
		got[0].rel_path == "monorepo/pkg/bar" && got[0].name == "bar",
		"expected monorepo/pkg/bar first, got %v/%v",
		got[0].rel_path,
		got[0].name,
	)
	testing.expectf(
		t,
		got[1].rel_path == "monorepo/pkg/foo" && got[1].name == "foo",
		"expected monorepo/pkg/foo second, got %v/%v",
		got[1].rel_path,
		got[1].name,
	)
	testing.expectf(t, len(warn) == 0, "unexpected warning %q", warn)
}

@(test)
test_scan_count_cap :: proc(t: ^testing.T) {
	// 202 candidate dirs but the default cap is 200 -> exactly 200, warning set.
	got, warn := core.scan_overlay_children(fake_listing, "cmb")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 200, "expected 200 children, got %v", len(got))
	testing.expectf(t, len(warn) > 0, "expected a cap warning, got empty")
}

@(test)
test_scan_depth_cap :: proc(t: ^testing.T) {
	// chain deeper than depth 3: nothing emitted but a warning (l4 unreached).
	got, warn := core.scan_overlay_children(fake_listing, "dp")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 0, "expected 0 children, got %v", len(got))
	testing.expectf(t, len(warn) > 0, "expected a depth-cap warning, got empty")
}

@(test)
test_scan_skip_hidden :: proc(t: ^testing.T) {
	got, warn := core.scan_overlay_children(fake_listing, "hid")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 1, "expected 1 child, got %v", len(got))
	testing.expectf(t, got[0].rel_path == "visible", "expected [visible], got %v", got[0].rel_path)
}

@(test)
test_scan_sort_deterministic :: proc(t: ^testing.T) {
	got, warn := core.scan_overlay_children(fake_listing, "srt")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 3, "expected 3 children, got %v", len(got))
	testing.expectf(
		t,
		got[0].rel_path == "a" && got[1].rel_path == "b" && got[2].rel_path == "z",
		"expected sorted [a b z], got %v %v %v",
		got[0].rel_path,
		got[1].rel_path,
		got[2].rel_path,
	)
}

@(test)
test_scan_vendor_clamped_and_nested :: proc(t: ^testing.T) {
	got, warn := core.scan_overlay_children(fake_listing, "ven")
	defer free_children(got)
	defer free_warn(warn)
	rels := make([dynamic]string, 0, len(got))
	defer delete(rels)
	for c in got {
		append(&rels, c.rel_path)
	}
	has_vendor := false
	has_nested := false
	has_vendor_sub := false
	for r in rels {
		if r == "vendor" {
			has_vendor = true
		}
		if r == "monorepo/pkg/foo" {
			has_nested = true
		}
		if r == "vendor/sub" {
			has_vendor_sub = true
		}
	}
	testing.expectf(t, has_vendor, "expected vendor child, got %v", rels)
	testing.expectf(t, has_nested, "expected monorepo/pkg/foo child, got %v", rels)
	testing.expectf(
		t,
		!has_vendor_sub,
		"vendor.sub must not be scanned (vendor clamped), got %v",
		rels,
	)
}

@(test)
test_scan_empty_root :: proc(t: ^testing.T) {
	got, warn := core.scan_overlay_children(fake_listing, "emp")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 0, "expected 0 children, got %v", len(got))
	testing.expectf(t, len(warn) == 0, "unexpected warning %q", warn)
}

@(test)
test_scan_missing_root_fails_open :: proc(t: ^testing.T) {
	got, warn := core.scan_overlay_children(fake_listing, "missing")
	defer free_children(got)
	defer free_warn(warn)
	testing.expectf(t, len(got) == 0, "expected 0 children (fail-open), got %v", len(got))
	testing.expectf(t, len(warn) == 0, "unexpected warning %q on fail-open", warn)
}
