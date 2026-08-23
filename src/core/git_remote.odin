package core

import "core:fmt"
import "core:os"
import "core:strings"

// read_origin_url reads `<child_path>/.git/config` and returns the URL of the
// `[remote "origin"]` section. The contract is fail-open: any missing file,
// unreadable path, worktree-style `.git` (a *file* containing `gitdir: ...`),
// absent origin section, or origin without a `url` line yields ok=false.
// No subprocesses are spawned — plain file reads only, so the single-threaded
// event loop never blocks.
read_origin_url :: proc(child_path: string, allocator := context.allocator) -> (string, bool) {
	git_path := fmt.tprintf("%s/.git", child_path)

	// A worktree-style `.git` is a regular file containing `gitdir: ...`;
	// do not follow it — treat as no URL.
	if !os.is_directory(git_path) {
		return "", false
	}

	data, rerr := os.read_entire_file(fmt.tprintf("%s/config", git_path), allocator)
	if rerr != nil {
		return "", false
	}
	defer delete(data, allocator)

	text := strings.trim_space(string(data))
	in_origin := false
	i, n := 0, len(text)
	for i < n {
		// Find end of line.
		j := i
		for j < n && text[j] != '\n' {
			j += 1
		}
		line := trim_ini_line(text[i:j])
		i = j + 1

		if len(line) == 0 {
			continue
		}

		if line[0] == '[' {
			// Section header; tolerate whitespace anywhere inside the brackets.
			end := strings.index_byte(line, ']')
			if end < 0 {
				in_origin = false
				continue
			}
			in_origin = section_is_origin(line[1:end])
			continue
		}

		if in_origin {
			eq := strings.index_any(line, "=")
			if eq < 0 {
				continue
			}
			key := strings.trim_space(line[:eq])
			value := strings.trim_space(line[eq + 1:])
			if key == "url" && len(value) > 0 {
				url := strings.clone(value, allocator)
				return url, true
			}
		}
	}

	return "", false
}

// trim_ini_line strips surrounding whitespace, drops full-line comments
// ('#' or ';'), and cuts trailing comments that follow whitespace so inline
// values like `url = a#b.git` survive.
trim_ini_line :: proc(line_param: string) -> string {
	line := strings.trim_space(line_param)
	if len(line) > 0 && (line[0] == '#' || line[0] == ';') {
		return ""
	}
	for i := 1; i < len(line); i += 1 {
		if (line[i] == '#' || line[i] == ';') && (line[i - 1] == ' ' || line[i - 1] == '\t') {
			return strings.trim_space(line[:i])
		}
	}
	return line
}

// section_is_origin reports whether a section-header body (between the
// brackets) names the origin remote, e.g. `remote "origin"`. Whitespace is
// ignored; the section name itself is matched case-insensitively.
section_is_origin :: proc(body: string) -> bool {
	target := `"origin"`

	// Collect the non-whitespace characters into a fixed buffer.
	buf: [64]byte
	k := 0
	for i := 0; i < len(body); i += 1 {
		c := body[i]
		if c == ' ' || c == '\t' {
			continue
		}
		if k >= len(buf) {
			return false
		}
		buf[k] = c
		k += 1
	}
	norm := string(buf[:k])

	if !strings.has_suffix(norm, target) {
		return false
	}
	prefix := norm[:k - len(target)]
	if len(prefix) == 0 {
		return true
	}
	// Case-insensitive comparison against "remote".
	if len(prefix) != len("remote") {
		return false
	}
	remote := "remote"
	for i := 0; i < len(remote); i += 1 {
		c := prefix[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != remote[i] {
			return false
		}
	}
	return true
}
