package core

import "core:slice"
import "core:strings"

// match_overlay_children filters workspace candidate paths against the
// overlay's attribute names and returns the children to splice.
//
// Candidates are relative paths (workspace-root-relative) of first-level
// directories plus their immediate subdirectories, e.g. "repo" or
// "monorepo/pkg/foo". A candidate matches when its basename is in attr_names.
// Deepest-match-wins: any matched candidate that is a path prefix of another
// matched candidate is dropped, so if both "repo" and "repo/sub" match, only
// "repo/sub" is spliced. The output is sorted deterministically by rel_path.
//
// Pure function: no I/O, no global state. The returned slice is allocated
// from `allocator` (default context.allocator) and owned by the caller; the
// strings inside it borrow from `candidates` and `attr_names` keys.
match_overlay_children :: proc(
	candidates: []string,
	attr_names: map[string]bool,
	allocator := context.allocator,
) -> []string {
	matched := make([dynamic]string, 0, len(candidates), allocator)
	for c in candidates {
		if !attr_names[path_basename(c)] {
			continue
		}
		keep := true
		for m in matched {
			if strings.has_prefix(m, c) && len(m) > len(c) && m[len(c)] == '/' {
				// A previously accepted deeper candidate sits under this one:
				// drop this shallower ancestor.
				keep = false
				break
			}
			if strings.has_prefix(c, m) && len(c) > len(m) && c[len(m)] == '/' {
				// This candidate is a strict path-prefix of an earlier one —
				// cannot happen with well-formed candidate sets (parents come
				// first), but guard for robustness.
				remove_idx := -1
				for mm, i in matched {
					if mm == m {
						remove_idx = i
						break
					}
				}
				if remove_idx >= 0 {
					unordered_remove(&matched, remove_idx)
				}
			}
		}
		if keep {
			append(&matched, c)
		}
	}

	slice.sort_by(matched[:], proc(a, b: string) -> bool {
		return a < b
	})
	return matched[:]
}

// path_basename returns everything after the last '/' in p (or p itself).
path_basename :: proc(p: string) -> string {
	last := -1
	for i := len(p) - 1; i >= 0; i -= 1 {
		if p[i] == '/' {
			last = i
			break
		}
	}
	return p[last + 1:]
}

// unordered_remove removes element at index i from a dynamic slice without
// preserving order (swap-with-last).
unordered_remove :: proc(d: ^[dynamic]string, i: int) {
	last := len(d) - 1
	d[i] = d[last]
	pop(d)
}
