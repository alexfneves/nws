package core

import "core:slice"
import "core:strings"

// merge_children unions the recursive built-in scan's children with an
// external resolver's children, producing the final managed child set for an
// overlay workspace.
//
// Semantics:
//   1. Union + dedup BY rel_path: every rel_path appears at most once in the
//      result; the FIRST occurrence wins walking `builtin` then `resolver`,
//      so the built-in scan is authoritative when both name the same physical
//      directory.
//   2. Same name but DIFFERENT rel_path (a resolver package shadowing a
//      built-in one at another location): the resolver wins — each builtin
//      entry whose name collides with a surviving resolver entry is dropped
//      and a non-empty `warning` is returned for the caller to log. Duplicate
//      Nix attr keys would hard-break eval, so the resolver is authoritative
//      for the name→path binding.
//   3. Final result is sorted deterministically by (rel_path, name). This
//      mirrors the scan's own output order, so merging an already-sorted scan
//      is stable; the generator independently re-sorts by (name, rel_path)
//      internally, so provenance never surfaces in the emitted flake.
//
// Pure: no I/O, no threads, inputs are borrowed (never mutated, never freed).
// The returned children own freshly allocated name/rel_path strings plus the
// backing slice; `warning` is a heap string when non-empty ("", a zero-length
// value, otherwise). The caller frees both.
merge_children :: proc(
	builtin: []Overlay_Child,
	resolver: []Overlay_Child,
	allocator := context.allocator,
) -> (
	children: []Overlay_Child,
	warning: string,
) {
	// ---- Step 1: union + dedup by rel_path (first occurrence wins). ----
	out := make([dynamic]Overlay_Child, 0, len(builtin) + len(resolver), allocator)
	res_kept := make([dynamic]int, 0, len(resolver), allocator)

	// Built-in entries pass through first; defensively skip any rel_path that
	// would otherwise duplicate (the scanner never emits duplicates, but the
	// merge contract holds for arbitrary input).
	for c in builtin {
		if _merge_has_rel(out[:], c.rel_path) {
			continue
		}
		append(
			&out,
			Overlay_Child {
				name = strings.clone(c.name, allocator),
				rel_path = strings.clone(c.rel_path, allocator),
			},
		)
	}
	// Resolver entries that did not collide on rel_path are kept; record their
	// indices in `out` so step 2 can distinguish resolver entries from builtin
	// ones when resolving name collisions.
	for c in resolver {
		if _merge_has_rel(out[:], c.rel_path) {
			continue
		}
		append(&res_kept, len(out))
		append(
			&out,
			Overlay_Child {
				name = strings.clone(c.name, allocator),
				rel_path = strings.clone(c.rel_path, allocator),
			},
		)
	}

	// ---- Step 2: resolver wins on same-name/different-rel collisions. ----
	// Collect the set of surviving resolver names (borrowed; `out` owns them).
	res_names := make([dynamic]string, 0, len(res_kept), allocator)
	for ri in res_kept {
		nm := out[ri].name
		if !_merge_has_name(res_names[:], nm) {
			append(&res_names, nm)
		}
	}

	// Compact: keep resolver entries and non-colliding builtin entries; drop
	// (free) builtin entries whose name a surviving resolver entry owns, and
	// record the shadowing in the warning.
	compacted := make([dynamic]Overlay_Child, 0, len(out), allocator)
	defer delete(out)
	defer delete(res_kept)
	defer delete(res_names)
	warn := strings.builder_make(allocator)
	defer strings.builder_destroy(&warn)
	first_conflict := true
	for ci := 0; ci < len(out); ci += 1 {
		is_res := false
		for ri in res_kept {
			if ri == ci {
				is_res = true
				break
			}
		}
		c := out[ci]
		if !is_res && _merge_has_name(res_names[:], c.name) {
			if first_conflict {
				strings.write_string(&warn, "resolver replaces builtin child: ")
				first_conflict = false
			} else {
				strings.write_string(&warn, ", ")
			}
			strings.write_string(&warn, c.name)
			strings.write_string(&warn, " (rel ")
			strings.write_string(&warn, c.rel_path)
			strings.write_byte(&warn, ')')
			delete(c.name)
			delete(c.rel_path)
			continue
		}
		append(&compacted, c) // ownership moves from `out` to `compacted`
	}

	// ---- Step 3: deterministic sort by (rel_path, name). ----
	slice.sort_by(compacted[:], proc(a, b: Overlay_Child) -> bool {
		if a.rel_path != b.rel_path {
			return a.rel_path < b.rel_path
		}
		return a.name < b.name
	})

	if first_conflict {
		warning = ""
	} else {
		warning = strings.clone(strings.to_string(warn), allocator)
	}
	return compacted[:], warning
}

// _merge_has_rel reports whether `rel` already appears as a rel_path among
// `list`, backing the rel_path-dedup (first-occurrence-wins) pass.
_merge_has_rel :: proc(list: []Overlay_Child, rel: string) -> bool {
	for c in list {
		if c.rel_path == rel {
			return true
		}
	}
	return false
}

// _merge_has_name reports whether `name` appears among the surviving
// resolver-name strings in `names`.
_merge_has_name :: proc(names: []string, name: string) -> bool {
	for n in names {
		if n == name {
			return true
		}
	}
	return false
}
