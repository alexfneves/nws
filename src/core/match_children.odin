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
	// Pass 1: collect every candidate whose basename is an attr name.
	matched := make([dynamic]string, 0, len(candidates), allocator)
	for c in candidates {
		if attr_names[path_basename(c)] {
			append(&matched, c)
		}
	}

	// Pass 2: deepest-match-wins. Drop any match that is a strict path
	// prefix of another match. No mutation while iterating.
	result := make([dynamic]string, 0, len(matched), allocator)
	for m in matched {
		keep := true
		for o in matched {
			if o != m && len(o) > len(m) && strings.has_prefix(o, m) && o[len(m)] == '/' {
				keep = false
				break
			}
		}
		if keep {
			append(&result, m)
		}
	}
	delete(matched)

	slice.sort_by(result[:], proc(a, b: string) -> bool {
		return a < b
	})
	return result[:]
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
