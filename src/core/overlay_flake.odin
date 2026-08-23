package core

import "core:slice"
import "core:strings"

// Overlay_Child describes one matched child directory spliced into an
// overlay workspace's package set. `name` is the attribute name under the
// overlay's attrPath (the candidate basename); `rel_path` is its path
// relative to the workspace root, used verbatim in `callPackage ./<rel_path>
// {}` (monorepo splices may contain `/`). Both strings are borrowed by the
// generated text and must outlive the call.
Overlay_Child :: struct {
	name:     string,
	rel_path: string,
}

// generate_overlay_root_flake builds a complete root flake.nix for a
// workspace with `"backend": "overlay"`: it imports each configured overlay,
// applies them over nixpkgs (per the nixpkgs cascade), and splices the
// matched children into each configured attrPath via
// `callPackage ./<rel_path> {}`.
//
// Like generate_root_flake this is a pure function of its arguments: children
// are emitted sorted by name (ties broken by rel_path), everything is written
// into a fresh builder, and the result is cloned — calling it twice with
// equal inputs yields byte-identical output.
//
// nixpkgs cascade (first match wins):
//  1. cfg.nixpkgs_url != ""            → inputs.nixpkgs.url = <url>
//  2. else any flake overlay entry     → inputs.nixpkgs.follows =
//     "<first-flake-input>/nixpkgs"
//  3. else                             → plain `import <nixpkgs>`
//
// Non-flake entries (`is_flake == false`) are imported via
// `import (builtins.fetchTarball "<url>")` instead of a flake input.
//
// With zero matched children a minimal valid managed flake is emitted.
// The returned string is allocated from `allocator` and owned by the caller.
generate_overlay_root_flake :: proc(
	matched: []Overlay_Child,
	cfg: Workspace_Config,
	allocator := context.allocator,
) -> string {
	sorted := make([dynamic]Overlay_Child, 0, len(matched), allocator)
	defer delete(sorted)
	for c in matched {
		append(&sorted, c)
	}
	slice.sort_by(sorted[:], proc(a, b: Overlay_Child) -> bool {
		if a.name != b.name {
			return a.name < b.name
		}
		return a.rel_path < b.rel_path
	})

	// Zero children: minimal valid managed flake (still passes is_managed_root).
	if len(sorted) == 0 {
		b := strings.builder_make(allocator)
		defer strings.builder_destroy(&b)
		strings.write_string(&b, MANAGED_ROOT_HEADER)
		strings.write_string(&b, "\n{\n  outputs = { ... }: {};\n}\n")
		return strings.clone(strings.to_string(b), allocator)
	}

	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)

	strings.write_string(&b, MANAGED_ROOT_HEADER)
	strings.write_string(&b, "\n{\n")

	// --- inputs section ---
	flake_count := 0
	for ov in cfg.overlays {
		if !ov.is_flake {
			continue
		}
		if flake_count == 0 {
			strings.write_string(&b, "  inputs = {\n")
		}
		strings.write_string(&b, "    ")
		write_input_name(&b, flake_count)
		strings.write_string(&b, `.url = "`)
		nix_escape_string(&b, ov.url)
		strings.write_string(&b, "\";\n")
		flake_count += 1
	}
	use_follows := false
	if len(cfg.nixpkgs_url) > 0 {
		if flake_count == 0 {
			strings.write_string(&b, "  inputs = {\n")
		}
		strings.write_string(&b, `    nixpkgs.url = "`)
		nix_escape_string(&b, cfg.nixpkgs_url)
		strings.write_string(&b, "\";\n")
	} else if flake_count > 0 {
		// Cascade step 2: follow the first flake overlay's nixpkgs.
		use_follows = true
		strings.write_string(&b, "    nixpkgs.follows = \"")
		write_input_name(&b, 0)
		strings.write_string(&b, "/nixpkgs\";\n")
	}
	if flake_count > 0 || len(cfg.nixpkgs_url) > 0 {
		strings.write_string(&b, "  };\n")
	}

	// --- outputs section ---
	strings.write_string(&b, "  outputs = { ... }@inputs:\n  let\n")
	for i in 0 ..< len(cfg.overlays) {
		strings.write_string(&b, "    overlayExpr")
		write_int(&b, i)
		strings.write_string(&b, " = ")
		if cfg.overlays[i].is_flake {
			strings.write_string(&b, "import inputs.")
			write_input_name(&b, i)
			strings.write_string(&b, ";\n")
		} else {
			// Non-flake entry: plain expression fetched as a tarball (ISC-13).
			strings.write_string(&b, `import (builtins.fetchTarball "`)
			nix_escape_string(&b, cfg.overlays[i].url)
			strings.write_string(&b, "\");\n")
		}
	}
	strings.write_string(&b, "    overlaysList = [\n")
	for i in 0 ..< len(cfg.overlays) {
		strings.write_string(&b, "      overlayExpr")
		write_int(&b, i)
		strings.write_string(&b, ".overlays.\"")
		attr := cfg.overlays[i].overlay_attr
		if len(attr) == 0 {
			attr = "default"
		}
		nix_escape_string(&b, attr)
		strings.write_string(&b, "\"\n")
	}
	strings.write_string(&b, "    ];\n")
	strings.write_string(&b, "    pkgs = ")
	if len(cfg.nixpkgs_url) > 0 || use_follows {
		strings.write_string(&b, "import inputs.nixpkgs ")
	} else {
		// Cascade step 3: plain channel import.
		strings.write_string(&b, "import <nixpkgs> ")
	}
	strings.write_string(&b, "{ overlays = overlaysList; };\n")
	strings.write_string(&b, "  in\n  {\n")

	// One output attribute per configured overlay entry: the upstream
	// attrPath extended with every matched child. Children are spliced under
	// each attrPath (v1 targets the single-entry case; multi-entry simply
	// repeats the splice set).
	for e in 0 ..< len(cfg.overlays) {
		strings.write_string(&b, "    ")
		write_attr_path(&b, cfg.overlays[e].attr_path)
		strings.write_string(&b, " = (pkgs.")
		write_attr_path(&b, cfg.overlays[e].attr_path)
		strings.write_string(&b, " or {}) // {\n")
		for c in sorted {
			strings.write_string(&b, "      ")
			write_attr_key(&b, c.name)
			strings.write_string(&b, " = pkgs.callPackage ./")
			nix_escape_string(&b, c.rel_path)
			strings.write_string(&b, " { };\n")
		}
		strings.write_string(&b, "    };\n")
	}

	strings.write_string(&b, "  };\n}\n")

	return strings.clone(strings.to_string(b), allocator)
}

// write_input_name writes the flake input name for the i-th *flake* overlay
// entry ("overlay0", "overlay1", ...) — deterministic and always a valid Nix
// identifier regardless of the URL contents.
write_input_name :: proc(b: ^strings.Builder, i: int) {
	strings.write_string(b, "overlay")
	write_int(b, i)
}

// write_int writes i in decimal (i >= 0).
write_int :: proc(b: ^strings.Builder, i: int) {
	n := i
	if n == 0 {
		strings.write_rune(b, '0')
		return
	}
	digits: [20]byte
	count := 0
	for n > 0 {
		digits[count] = byte('0' + n % 10)
		n /= 10
		count += 1
	}
	for j := count - 1; j >= 0; j -= 1 {
		strings.write_byte(b, digits[j])
	}
}

// write_attr_path writes a dotted attrPath ("rosPackages.humble") as bare
// attrset keys (works both in definition and selector position), quoting any
// segment that is not a valid Nix identifier.
write_attr_path :: proc(b: ^strings.Builder, path: string) {
	segs := strings.split(path, ".")
	defer delete(segs)
	for seg, i in segs {
		if i > 0 {
			strings.write_byte(b, '.')
		}
		write_attr_key(b, seg)
	}
}
