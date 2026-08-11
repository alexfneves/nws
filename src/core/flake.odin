package core

import "core:fmt"
import "core:strings"

// sync_flake rewrites a flake.nix input so cloned repos are pinned to
// `path:./<NAME>` (with a `# nws: <canonical>` marker) and previously-managed
// repos whose clone was removed are restored to their canonical URL.
//
// It is a pure, line-based, fail-open transform: lines that don't match a
// `NAME.url = "VALUE";` assignment (nested attrs, comments, malformed input)
// are passed through unchanged. Run twice, it is idempotent — it never
// appends a duplicate `# nws:` marker.
//
// Returns the resulting text and whether it differs from the input.
sync_flake :: proc(
	input_text: string,
	local_repos: []string,
	allocator := context.allocator,
) -> (
	new_text: string,
	changed: bool,
) {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	start := 0
	for start <= len(input_text) {
		nl := strings.index_byte(input_text[start:], '\n')
		line: string
		had_newline := nl >= 0
		if had_newline {
			line = input_text[start:start + nl]
			start = start + nl + 1
		} else {
			line = input_text[start:]
			start = len(input_text) + 1
		}

		out, is_new := process_line(line, local_repos, allocator)
		if out != line {
			changed = true
		}
		strings.write_string(&b, out)
		if had_newline {
			strings.write_string(&b, "\n")
		}
		if is_new {
			delete(out, allocator)
		}
	}

	return strings.clone(strings.to_string(b), allocator), changed
}

// process_line applies the transform to a single line (no trailing newline).
// Unparseable or unmanaged lines are returned unchanged.
process_line :: proc(
	line: string,
	local_repos: []string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	// Capture the leading indentation; operate on the trimmed body.
	body_offset := 0
	for body_offset < len(line) && (line[body_offset] == ' ' || line[body_offset] == '\t') {
		body_offset += 1
	}
	indent := line[:body_offset]
	body := line[body_offset:]

	// Locate ".url" and the single identifier before it.
	url_idx := strings.index(body, ".url")
	if url_idx < 0 {
		return line, false
	}
	name_end := url_idx
	name_start := name_end
	for name_start > 0 && is_ident_char(body[name_start - 1]) {
		name_start -= 1
	}
	if name_start == name_end {
		return line, false // no identifier before ".url"
	}
	name := body[name_start:url_idx]
	// The identifier must be a bare token (no nested dots before ".url").
	if name_start > 0 {
		c := body[name_start - 1]
		if c != ' ' && c != '\t' && c != '{' && c != ',' {
			return line, false
		}
	}

	// After ".url" require exactly ` = "` (double-quoted value, no nested attrs).
	value_offset := url_idx + len(".url") + len(` = "`)
	if value_offset > len(body) || !strings.has_prefix(body[url_idx + len(".url"):], ` = "`) {
		return line, false
	}

	rest := body[value_offset:]
	close_idx := strings.index_byte(rest, '"')
	if close_idx <= 0 {
		return line, false // empty or corrupt value
	}
	value := rest[:close_idx]

	// After the closing quote require ';', then (optionally) a marker comment.
	tail := rest[close_idx + 1:]
	if !strings.has_prefix(tail, ";") {
		return line, false
	}
	after_semi := tail[len(";"):]

	marker_canonical, has_marker := extract_marker(after_semi)
	is_local := contains(local_repos, name)

	if !is_local && !has_marker {
		return line, false // unmanaged repo, never cloned — leave untouched
	}

	canonical := value
	if has_marker {
		canonical = marker_canonical
	}

	new_url: string
	if is_local {
		new_url = fmt.tprintf("path:./%s", name)
	} else {
		// clone removed — restore the canonical URL, keep the marker.
		new_url = canonical
	}

	// Rebuild the line, preserving the original indentation and any trailing
	// content after the ';' (comments, the existing marker) verbatim. Only
	// append a `# nws:` marker when one isn't already present, so repeated
	// rewrites never duplicate it.
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, indent)
	strings.write_string(&b, name)
	strings.write_string(&b, `.url`)
	strings.write_string(&b, ` = "`)
	strings.write_string(&b, new_url)
	strings.write_string(&b, `";`)
	strings.write_string(&b, after_semi)
	if !has_marker {
		strings.write_string(&b, `  # nws: `)
		strings.write_string(&b, canonical)
	}
	return strings.clone(strings.to_string(b), allocator), true
}

// extract_marker parses an existing `# nws: <canonical>` marker. Returns the
// canonical string (trimmed) and whether a marker was found at all.
extract_marker :: proc(s: string) -> (canonical: string, found: bool) {
	idx := strings.index(s, "# nws:")
	if idx < 0 {
		return "", false
	}
	return strings.trim_space(s[idx + len("# nws:"):]), true
}

is_ident_char :: proc(c: byte) -> bool {
	return(
		c == '_' ||
		c == '-' ||
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') \
	)
}

contains :: proc(list: []string, s: string) -> bool {
	for item in list {
		if item == s {
			return true
		}
	}
	return false
}
