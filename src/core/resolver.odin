package core

import "core:os"
import "core:strings"

// Resolver line parsing and subprocess runner.
//
// The resolver is a user-supplied script that returns one line per discovered
// external package: `NAME\tRELPATH`, where NAME is the overlay attribute key
// and RELPATH is the package path relative to the workspace root. Both this
// parser and the runner are fail-open: a malformed/no-tab/blank line is
// skipped without aborting the rest, and a non-zero subprocess exit yields an
// empty result with ok=false. Everything runs on the daemon's single thread —
// the runner shells the script once inline via core:os process_exec (the
// accepted non-threaded debt), never spawning concurrent work.

// parse_resolver_lines parses `NAME\tRELPATH` lines from the resolver script's
// stdout. Each line is whitespace-trimmed; blank lines are skipped; lines
// without a tab, or with an empty NAME or RELPATH after trimming, are
// malformed and skipped (fail-open — parsing continues past them). Empty input
// yields no children and ok=true. A RELPATH that is not relative to the
// workspace root (absolute, beginning with '/') is a hard error: the parse
// aborts returning an empty result and ok=false. The returned children own
// freshly allocated name/rel_path strings and the backing slice — free with
// free_resolver_children.
parse_resolver_lines :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	children: []Overlay_Child,
	ok: bool,
) {
	out := make([dynamic]Overlay_Child, 0, allocator)
	lines := strings.split(text, "\n", allocator)
	defer delete(lines)

	ok = true
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 {
			continue // blank / whitespace-only line — skip
		}
		tab := strings.index_byte(trimmed, '\t')
		if tab < 0 {
			continue // no tab — malformed, fail-open skip
		}
		name := strings.trim_space(trimmed[:tab])
		rel := strings.trim_space(trimmed[tab + 1:])
		if len(name) == 0 || len(rel) == 0 {
			continue // empty name or empty rel_path — malformed, fail-open skip
		}
		if rel[0] == '/' {
			// Not relative to the workspace root — hard error, fail closed.
			// free_resolver_children releases the child strings AND the dynamic
			// backing array (via `delete(children)` on the out[:] slice), so `out`
			// must not be deleted a second time here.
			free_resolver_children(out[:])
			return nil, false
		}
		append(
			&out,
			Overlay_Child {
				name = strings.clone(name, allocator),
				rel_path = strings.clone(rel, allocator),
			},
		)
	}
	return out[:], true
}

// run_resolver shells the user's resolver `script` once, using
// `workspace_path` as the process cwd and argv[1]. Its stdout is parsed with
// parse_resolver_lines. Any spawn failure or non-zero exit is fail-open:
// empty children and ok=false (a partial/good output from a zero-exit run
// still yields its children). Inline-blocking and thread-free, matching the
// daemon's single-threaded event loop.
run_resolver :: proc(
	script: string,
	workspace_path: string,
	allocator := context.allocator,
) -> (
	children: []Overlay_Child,
	ok: bool,
) {
	argv := make([dynamic]string, 0, 2, allocator)
	defer delete(argv)
	append(&argv, script)
	append(&argv, workspace_path)
	desc := os.Process_Desc {
		working_dir = workspace_path,
		command     = argv[:],
	}
	state, stdout_bytes, _, err := os.process_exec(desc, allocator)
	if err != nil || !state.success {
		// Spawn failure or non-zero exit / crash: fail-open, no children.
		delete(stdout_bytes)
		return nil, false
	}
	defer delete(stdout_bytes)
	return parse_resolver_lines(string(stdout_bytes), allocator)
}

// free_resolver_children releases the owned name/rel_path strings plus the
// backing slice of one resolver result.
free_resolver_children :: proc(children: []Overlay_Child) {
	for c in children {
		delete(c.name)
		delete(c.rel_path)
	}
	delete(children)
}
