package core

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

// Dir_Entry is one entry returned by the injected directory-listing seam.
// `name` is its basename; `is_dir` distinguishes subdirectories from files.
Dir_Entry :: struct {
	name:   string, // basename
	is_dir: bool,
}

// Dir_List groups the entries of one directory. Defined as part of the
// scanner's public seam shape (matches the "directory-listing" abstraction);
// the listing proc currently returns `[]Dir_Entry` directly, so this type is
// retained for callers that want a grouped view.
Dir_List :: struct {
	entries: []Dir_Entry,
}

// Dir_Listing_Proc is the injection seam through which scan_overlay_children
// reads directory contents, keeping the scanner pure (no real FS, no threads).
// Tests inject a fake in-memory tree; the daemon injects a real adapter over
// os.read_directory_by_path. The proc returns the directory's entries with
// their `name` strings allocated into the passed allocator (owned by the
// scanner, which frees them), plus an ok flag: false means fail-open (the dir
// is skipped as if empty, never failing the scan).
Dir_Listing_Proc :: #type proc(
	dir: string,
	allocator: mem.Allocator,
) -> (
	entries: []Dir_Entry,
	ok: bool,
)

// Frame is one pending scan-descent: `dir` is the physical path to list,
// `rel` its path relative to the workspace root ("" for the root itself).
Frame :: struct {
	dir: string,
	rel: string,
}
// scan_overlay_children recursively lists the workspace `root` (rel "" path)
// and emits one Overlay_Child per directory that owns `flake.nix` OR any
// `.nix` file, never descending INTO such a directory (clamp at the package
// boundary), so nested workspace trees yield one package per flake/dir folder.
//
// Hidden entries — any basename starting with '.', e.g. `.git`, `.nws` — are
// skipped: they are never children and are never descended into. Children are
// returned sorted by rel_path (deterministic). Scanning is bounded by `depth`
// (max path segments below root, default 3, so `monorepo/pkg/foo` is the
// deepest recognized shape) and `max_count` children; on hitting a cap,
// `warning` becomes non-empty (the caller logs it) and the scan stops at that
// boundary — it never fails.
//
// Pure by construction: no file I/O, no process spawns, no threads; every
// descendant is read through the `dir_list` seam. The returned slice and its
// child `name`/`rel_path` strings are allocated from `allocator` and owned by
// the caller (free with delete).
scan_overlay_children :: proc(
	dir_list: Dir_Listing_Proc,
	root: string,
	depth: int = 3,
	max_count: int = 200,
	allocator := context.allocator,
) -> (
	children: []Overlay_Child,
	warning: string,
) {
	out := make([dynamic]Overlay_Child, 0, allocator)
	warn := strings.builder_make(allocator)
	warned := false
	capped := false

	// A breadth-first traversal frame: `dir` is the physical path to list,
	// `rel` its path relative to root ("" for the root itself). Each string
	// is heap-owned and freed when its frame is popped (or when the scan
	// stops early).
	frames := make([dynamic]Frame, 0, allocator)
	append(&frames, Frame{dir = strings.clone(root, allocator), rel = ""})

	front := 0
	count := 0
	for front < len(frames) && !capped {
		fr := frames[front]
		front += 1

		entries, ok := dir_list(fr.dir, allocator)
		if !ok {
			// Fail-open: treat an unreadable directory as empty.
			delete(fr.dir)
			delete(fr.rel)
			continue
		}

		// Classify entries while they are alive: collect subdirectory names
		// (borrowed) and detect whether this directory owns a package marker.
		has_nix := false
		subs := make([dynamic]string, 0, allocator)
		for e in entries {
			if len(e.name) == 0 || e.name[0] == '.' {
				continue // hidden: never a child, never descended into
			}
			if e.is_dir {
				append(&subs, e.name)
			} else if e.name == "flake.nix" || strings.has_suffix(e.name, ".nix") {
				has_nix = true
			}
		}
		// Deterministic descent order so count-cap cutoffs are stable.
		slice.sort_by(subs[:], proc(a, b: string) -> bool {
			return a < b
		})

		// A subdirectory (not the root) owning a package marker is a child:
		// emit it and clamp — never descend below the package boundary.
		if fr.rel != "" && has_nix {
			count += 1
			if count > max_count {
				if !warned {
					strings.write_string(
						&warn,
						fmt.tprintf(
							"overlay child scan capped at %d children (max %d); further children omitted",
							count - 1,
							max_count,
						),
					)
					warned = true
				}
				capped = true
			} else {
				append(
					&out,
					Overlay_Child {
						name = strings.clone(path_last_segment(fr.rel), allocator),
						rel_path = strings.clone(fr.rel, allocator),
					},
				)
			}
			_free_entries(entries)
			delete(subs)
			delete(fr.dir)
			delete(fr.rel)
			continue
		}

		segs := 0
		if fr.rel != "" {
			segs = segment_count(fr.rel)
		}

		// Depth cap: at the boundary with subdirectories still present, deeper
		// descendants exist but are not explored — warn once and stop this branch.
		if fr.rel != "" && segs >= depth && len(subs) > 0 && !capped {
			if !warned {
				strings.write_string(
					&warn,
					fmt.tprintf(
						"overlay child scan stopped at depth %d (cap %d); deeper nested children omitted",
						segs,
						depth,
					),
				)
				warned = true
			}
			_free_entries(entries)
			delete(subs)
			delete(fr.dir)
			delete(fr.rel)
			continue
		}

		if segs < depth {
			for s in subs {
				sub_rel := ""
				if fr.rel == "" {
					sub_rel = strings.clone(s, allocator)
				} else {
					sub_rel = strings.concatenate([]string{fr.rel, "/", s}, allocator)
				}
				sub_dir := strings.concatenate([]string{fr.dir, "/", s}, allocator)
				append(&frames, Frame{dir = sub_dir, rel = sub_rel})
			}
		}
		_free_entries(entries)
		delete(subs)
		delete(fr.dir)
		delete(fr.rel)
	}

	// Free any frames left pending when the scan stopped early (count cap).
	for i := front; i < len(frames); i += 1 {
		delete(frames[i].dir)
		delete(frames[i].rel)
	}
	delete(frames)

	// Children pinned: rel_path is relative to root. Sort for determinism.
	slice.sort_by(out[:], proc(a, b: Overlay_Child) -> bool {
		if a.rel_path != b.rel_path {
			return a.rel_path < b.rel_path
		}
		return a.name < b.name
	})

	if warned {
		warning = strings.clone(strings.to_string(warn), allocator)
	} else {
		warning = ""
	}
	strings.builder_destroy(&warn)

	return out[:], warning
}

// _free_entries releases an array of Dir_Entry together with its `name`
// strings, matching the seam's allocation contract (names use `allocator`).
_free_entries :: proc(entries: []Dir_Entry) {
	for e in entries {
		delete(e.name)
	}
	delete(entries)
}

// path_last_segment returns everything after the last '/' in p.
path_last_segment :: proc(p: string) -> string {
	last := -1
	for i := len(p) - 1; i >= 0; i -= 1 {
		if p[i] == '/' {
			last = i
			break
		}
	}
	return p[last + 1:]
}

// segment_count returns the number of path segments in a root-relative rel
// path ("" = 0). Used to enforce the depth cap.
segment_count :: proc(rel: string) -> int {
	if len(rel) == 0 {
		return 0
	}
	n := 1
	for c in rel {
		if c == '/' {
			n += 1
		}
	}
	return n
}
