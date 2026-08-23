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
			if is_nix_identifier(c.name) {
				strings.write_string(&b, c.name)
			} else {
				// Not a bare identifier: emit as a quoted attrset key so the
				// generated flake stays syntactically valid.
				strings.write_string(&b, "\"")
				nix_escape_string(&b, c.name)
				strings.write_string(&b, "\"")
			}
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

// is_managed_root reports whether the given flake text starts with the
// nws-managed header on its first line. Only managed roots may be
// regenerated by the daemon; anything else is user-authored.
is_managed_root :: proc(text: string) -> bool {
	return strings.has_prefix(text, MANAGED_ROOT_HEADER)
}
