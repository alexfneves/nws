package core

import "core:slice"
import "core:strings"

// Child_Info describes one first-level directory of a workspace.
// `name` is the directory (and Nix input) name; when `has_url` is true,
// `url` is the clone's canonical URL recorded as a `# nws:` marker comment;
// otherwise the input is emitted without any marker (fail-open path pin).
Child_Info :: struct {
	name:    string,
	url:     string,
	has_url: bool,
	// Names of flake inputs this child declares (parsed from its own
	// flake.nix while the clone is present). When one of these matches a
	// sibling child, the generator emits an override so the sibling resolves
	// locally: `<child>.inputs.<dep>.url = "path:./<dep>"`. May be nil.
	deps:    []string,
}

// MANAGED_ROOT_HEADER is the first line that marks a root flake.nix as
// nws-managed. A root flake without it is user-authored and never touched.
MANAGED_ROOT_HEADER :: "# nws-generated — do not edit"

// generate_root_flake builds a complete, syntactically valid workspace root
// flake.nix from the given children. It is a pure function of its arguments:
// children are emitted sorted by name regardless of input order, so calling
// it twice with equal inputs yields byte-identical output.
//
// Each cloned child becomes `inputs.<name>.url = "path:./<name>"` with an
// optional `# nws: <canonical-url>` marker comment (same semantics as
// extract_marker in flake.odin). The marker is emitted at most once per
// input by construction — generation never appends to existing text.
//
// Outputs delegate the children's packages/devShells/apps/checks under
// `<child>-` prefixed attribute names, which makes `.default` collisions
// impossible by construction.
generate_root_flake :: proc(children: []Child_Info, allocator := context.allocator) -> string {
	sorted := make([dynamic]Child_Info, 0, len(children), allocator)
	defer delete(sorted)
	for c in children {
		append(&sorted, c)
	}
	// Sort by name so output bytes never depend on directory enumeration order.
	slice.sort_by(sorted[:], proc(a, b: Child_Info) -> bool {
		return a.name < b.name
	})

	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, MANAGED_ROOT_HEADER)
	strings.write_string(&b, "\n{\n")
	if len(sorted) > 0 {
		strings.write_string(&b, "  inputs = {\n")
		for c in sorted {
			strings.write_string(&b, "    ")
			write_attr_key(&b, c.name)
			strings.write_string(&b, `.url = "path:./`)
			nix_escape_string(&b, c.name)
			strings.write_string(&b, `";`)
			if c.has_url {
				// Same `# nws: <canonical>` marker semantics as flake.odin;
				// emitted exactly once because we always generate fresh text.
				strings.write_string(&b, ` # nws: `)
				strings.write_string(&b, c.url)
			}
			strings.write_string(&b, "\n")
			emit_sibling_overrides(&b, c, sorted[:])
		}
		strings.write_string(&b, "  };\n")
	} else {
		// Minimal valid empty managed flake.
		strings.write_string(&b, "  inputs = {};\n")
	}

	root_flake_outputs(&b, sorted[:])
	strings.write_string(&b, "}\n")

	return strings.clone(strings.to_string(b), allocator)
}

// root_flake_outputs emits the `outputs` section delegating the children's
// packages/devShells/apps/checks under `<child>-` prefixed attribute names.
// With zero children every delegated output is simply an empty attrset.
root_flake_outputs :: proc(b: ^strings.Builder, sorted: []Child_Info) {
	strings.write_string(b, `  outputs = { self, ... }@inputs:` + "\n")
	strings.write_string(b, "  let\n")
	strings.write_string(b, `    children = [`)
	for c in sorted {
		strings.write_string(b, ` "`)
		nix_escape_string(b, c.name)
		strings.write_string(b, `"`)
	}
	strings.write_string(b, ` ];` + "\n")
	strings.write_string(b, `    delegate = out:` + "\n")
	strings.write_string(b, `      builtins.listToAttrs (builtins.concatMap` + "\n")
	strings.write_string(b, `        (child:` + "\n")
	strings.write_string(b, `          let v = inputs.${child}.${out} or null; in` + "\n")
	strings.write_string(b, `          if v == null then [] else` + "\n")
	strings.write_string(b, `          builtins.attrValues (builtins.mapAttrs` + "\n")
	strings.write_string(b, `            (sys: val: {` + "\n")
	strings.write_string(b, `              name = sys;` + "\n")
	strings.write_string(b, `              value = builtins.listToAttrs (builtins.map` + "\n")
	strings.write_string(
		b,
		`                (attrName: { name = "${child}-${attrName}"; value = v.${attrName}; })` +
		"\n",
	)
	strings.write_string(b, `                (builtins.attrNames v));` + "\n")
	strings.write_string(b, `            })` + "\n")
	strings.write_string(b, `            v)` + "\n")
	strings.write_string(b, `        )` + "\n")
	strings.write_string(b, `        children);` + "\n")
	strings.write_string(b, "  in\n")
	strings.write_string(b, "  {\n")
	strings.write_string(b, `    packages = delegate "packages";` + "\n")
	strings.write_string(b, `    devShells = delegate "devShells";` + "\n")
	strings.write_string(b, `    apps = delegate "apps";` + "\n")
	strings.write_string(b, `    checks = delegate "checks";` + "\n")
	strings.write_string(b, "  };\n")
}

// is_nix_identifier reports whether name is a valid bare Nix identifier
// ([A-Za-z_][A-Za-z0-9_'-]*), usable directly as an attrset key.
is_nix_identifier :: proc(name: string) -> bool {
	if len(name) == 0 {
		return false
	}
	for c, i in name {
		alpha := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
		if i == 0 {
			if !alpha {
				return false
			}
		} else if !alpha && !('0' <= c && c <= '9') && c != '\'' && c != '-' {
			return false
		}
	}
	return true
}

// nix_escape_string writes s into b escaped for safe inclusion inside a
// double-quoted Nix string literal: backslash, double quote, and the `${`
// anti-quotation sequence are neutralised.
nix_escape_string :: proc(b: ^strings.Builder, s: string) {
	i := 0
	for i < len(s) {
		switch {
		case s[i] == '"':
			strings.write_string(b, `\"`)
			i += 1
		case s[i] == '\\':
			strings.write_string(b, `\\`)
			i += 1
		case s[i] == '$' && i + 1 < len(s) && s[i + 1] == '{':
			strings.write_string(b, `\${`)
			i += 2
		case:
			strings.write_string(b, s[i:i + 1])
			i += 1
		}
	}
}

// write_attr_key writes name as an attrset key: bare when it is a valid Nix
// identifier, quoted+escaped otherwise.
write_attr_key :: proc(b: ^strings.Builder, name: string) {
	if is_nix_identifier(name) {
		strings.write_string(b, name)
	} else {
		strings.write_string(b, "\"")
		nix_escape_string(b, name)
		strings.write_string(b, "\"")
	}
}

// has_child_name reports whether any child in sorted has the given name.
has_child_name :: proc(sorted: []Child_Info, name: string) -> bool {
	for c in sorted {
		if c.name == name {
			return true
		}
	}
	return false
}

// emit_sibling_overrides writes `<child>.inputs.<dep>.url = "path:./<dep>"`
// lines for every dependency of child whose name matches another workspace
// child, in sorted dep order (allocation-free selection over deps). Self-
// references and deps that are not siblings are skipped.
emit_sibling_overrides :: proc(b: ^strings.Builder, c: Child_Info, sorted: []Child_Info) {
	last := ""
	for _round := 0; _round < len(c.deps); _round += 1 {
		best := -1
		for d, i in c.deps {
			if d == c.name || !has_child_name(sorted, d) {
				continue
			}
			if last != "" && d <= last {
				continue // already emitted (deps are duplicate-free)
			}
			if best == -1 || d < c.deps[best] {
				best = i
			}
		}
		if best == -1 {
			break
		}
		last = c.deps[best]
		strings.write_string(b, "    ")
		write_attr_key(b, c.name)
		strings.write_string(b, `.inputs.`)
		write_attr_key(b, last)
		strings.write_string(b, `.url = "path:./`)
		nix_escape_string(b, last)
		strings.write_string(b, `";`)
		strings.write_string(b, "\n")
	}
}

// parse_flake_input_names extracts the top-level input attribute names
// declared in a child flake.nix text. Conservative line-based parser:
//   NAME.url = ...;   captures NAME
//   NAME = { ... };   captures NAME (attrset form)
// Everything else (follows lines, nested inner keys like those inside
// `pyproject-build-systems = { inputs = {...} }`, comments, outputs) is
// ignored. Duplicates removed; order follows the file. The returned slice
// and its strings are allocated from the allocator and owned by the caller.
parse_flake_input_names :: proc(text: string, allocator := context.allocator) -> []string {
	names := make([dynamic]string, 0, 8, allocator)

	lines := strings.split(text, "\n")
	defer delete(lines)
	// Only lines inside the top-level `inputs = { ... }` block are
	// considered; a naive brace counter tracks nesting so we leave the block
	// when it closes (conservative: braces inside string literals can confuse
	// it, in which case we simply stop capturing — fail-open).
	in_inputs := false
	depth := 0
	for line in lines {
		t := strings.trim_space(line)
		if len(t) == 0 || t[0] == '#' {
			continue
		}
		if !in_inputs {
			if t == "inputs" ||
			   strings.has_prefix(t, "inputs ") ||
			   strings.has_prefix(t, "inputs=") {
				rest := strings.trim_space(t[len("inputs"):])
				if strings.has_prefix(rest, "=") && strings.contains(rest, "{") {
					in_inputs = true
					depth = count_braces(t)
				}
			}
			continue
		}
		depth += count_braces(t)
		if depth <= 0 {
			in_inputs = false
			continue
		}
		name, ok := parse_input_line_head(t)
		if !ok || name == "inputs" {
			continue
		}
		dup := false
		for existing in names {
			if existing == name {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		append(&names, strings.clone(name, allocator))
	}
	return names[:]
}

// count_braces counts '{' minus '}' occurrences in s.
count_braces :: proc(s: string) -> int {
	n := 0
	for c in s {
		if c == '{' {
			n += 1
		} else if c == '}' {
			n -= 1
		}
	}
	return n
}

// parse_input_line_head recognises the two input declaration shapes at the
// head of a trimmed line:
//
//	NAME.url = ...
//	NAME = { ...
//
// returning the name; ok=false otherwise.
parse_input_line_head :: proc(t: string) -> (name: string, ok: bool) {
	i := 0
	if i >= len(t) || !ident_start_byte(t[i]) {
		return
	}
	start := i
	for i < len(t) && ident_cont_byte(t[i]) {
		i += 1
	}
	name = t[start:i]
	j := i
	for j < len(t) && (t[j] == ' ' || t[j] == '\t') {
		j += 1
	}
	if j < len(t) && t[j] == '.' {
		// NAME.url = ...
		if strings.has_prefix(t[j:], ".url") {
			k := j + 4
			for k < len(t) && (t[k] == ' ' || t[k] == '\t') {
				k += 1
			}
			if k < len(t) && t[k] == '=' {
				return name, true
			}
		}
		return
	}
	if j < len(t) && t[j] == '=' {
		// NAME = { ...  (attrset form)
		k := j + 1
		for k < len(t) && (t[k] == ' ' || t[k] == '\t') {
			k += 1
		}
		if k < len(t) && t[k] == '{' {
			return name, true
		}
	}
	return
}

ident_start_byte :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

ident_cont_byte :: proc(c: byte) -> bool {
	return ident_start_byte(c) || (c >= '0' && c <= '9') || c == '\'' || c == '-'
}

// is_managed_root reports whether the given flake text starts with the
// nws-managed header on its first line. Only managed roots may be
// regenerated by the daemon; anything else is user-authored.
is_managed_root :: proc(text: string) -> bool {
	return strings.has_prefix(text, MANAGED_ROOT_HEADER)
}
